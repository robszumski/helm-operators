#!/bin/bash

echo -e "\nParsing Whitelist:"

# Settings
WHITELIST="whitelist.yaml"
CHART_SRC="/Users/robszumski/Documents/charts/stable"
SDK="/Users/robszumski/Documents/src/github.com/operator-framework/operator-sdk/build/operator-sdk-pr-949"
QUAY_REPO="quay.io/helmoperators"
ROOT_DIR="$PWD"
TEMP_DIR=$(mktemp -d)

# Create temodir and symlink into GOPATH
mkdir -p $ROOT_DIR/temp
ln -s $TEMP_DIR $ROOT_DIR/temp

build_sdk() {
	echo -e "\nBuilding SDK for: $1 ($CHART_SRC/$1)"

	cd $TEMP_DIR

	$SDK new $1 --type=helm --helm-chart-source="$CHART_SRC/$1" --cluster-scoped
}

build_image() {
	cd $1
	$SDK build "$QUAY_REPO/$1"
	docker build "$QUAY_REPO/$1"
}

get_previous_version() {
	CHART_VERSION=$(yq r $CHART_SRC/$1/Chart.yaml version)
	REMOTE_VERSION=$("$ROOT_DIR/read-quay-version.sh" $NAME)
	echo "  Quay's latest version for $1 chart is $REMOTE_VERSION"

	SEMVER="$ROOT_DIR/semver.sh"

	if [ "$REMOTE_VERSION" == "null" ]; then
		# There isn't a remote version, this is the first push add a -1 to it
		PREREL=0
		VERSION=$($SEMVER bump prerel $(($PREREL+1)) $CHART_VERSION)
		REPLACES=false
		echo "  Pushing $VERSION as the first release"
	elif [ $($SEMVER compare $REMOTE_VERSION $CHART_VERSION) -eq 0 ] ; then
		# This means a newer version of the CSV has been published than the chart contains, eg v1.2.3
		# this indicates that we have probably pushed a v1.2.3-1 with CSV related changes
		echo "  $REMOTE_VERSION is equal to chart's $CHART_VERSION!"
		if [[ -z $($SEMVER get prerel $REMOTE_VERSION) ]]; then
			# no -1, which means this needs a prerel added
			PREREL=$($SEMVER get prerel $REMOTE_VERSION)
			VERSION=$($SEMVER bump prerel $(($PREREL+1)) $REMOTE_VERSION)
			REPLACES=true
			echo "  Adding first prerel to $VERSION"
		elif [[ ! -z $($SEMVER get prerel $REMOTE_VERSION) ]]; then
			# there is a -1, which means we need to incrementit to 2
			PREREL=$($SEMVER get prerel $REMOTE_VERSION)
			VERSION=$($SEMVER bump prerel $(($PREREL+1)) $REMOTE_VERSION)
			REPLACES=true
			echo "  Bumped prerel tag, new version is $VERSION"
		fi
	elif [ $($SEMVER compare $REMOTE_VERSION $CHART_VERSION) -eq 1 ] ; then
		echo "  $REMOTE_VERSION is greater than chart's $CHART_VERSION!"
		# Blindly assume this just needs a prerel bump
		# todo: don't assume these are the same minor and patch version
		if [[ -z $($SEMVER get prerel $REMOTE_VERSION) ]]; then
			# no -1, which means this needs a prerel added
			PREREL=$($SEMVER get prerel $REMOTE_VERSION)
			VERSION=$($SEMVER bump prerel $(($PREREL+1)) $REMOTE_VERSION)
			REPLACES=true
			echo "  Adding first prerel to $VERSION"
		elif [[ ! -z $($SEMVER get prerel $REMOTE_VERSION) ]]; then
			# there is a -1, which means we need to incrementit to 2
			PREREL=$($SEMVER get prerel $REMOTE_VERSION)
			VERSION=$($SEMVER bump prerel $(($PREREL+1)) $REMOTE_VERSION)
			REPLACES=true
			echo "  Bumped prerel tag, new version is $VERSION"
		fi
	else 
		# Our local chart version is higher, we can proceed normally
		PREREL=$($SEMVER get prerel $CHART_VERSION)
		VERSION=$($SEMVER bump prerel $(($PREREL+1)) $CHART_VERSION)
		REPLACES=true
		echo "  Chart version is higher, setting to $VERSION"
	fi
}

build_csv() {
	echo -e "\nBuilding CSV for: $1"

	# Fetch info from Chart
	NAME=$1
	get_previous_version $NAME
	CSV_NAME="$NAME.v$VERSION"
	SOURCE_LINK=$(yq r $CHART_SRC/$NAME/Chart.yaml sources[0])
	ICON_SRC=$(yq r $CHART_SRC/$NAME/Chart.yaml icon)
	MAINTAINERS_NAME=$(yq r $CHART_SRC/$NAME/Chart.yaml maintainers[0].name)
	MAINTAINERS_EMAIL=$(yq r $CHART_SRC/$NAME/Chart.yaml maintainers[0].email)
	DESC=$(yq r $CHART_SRC/$NAME/Chart.yaml description)
	API_VERSION="v1alpha1"
	KIND=$(echo $NAME |  head -c 1 | tr [a-z] [A-Z]; echo $NAME | tail -c +2)

	# Make a directory to hold our files
	cd $ROOT_DIR
	mkdir -p $NAME

	# Write out CR metadata
	CR_OUT="$ROOT_DIR/$NAME/$NAME.cr.yaml"
	cp "$ROOT_DIR/cr.template" $CR_OUT

	# Grab default values, indent them, and append to CR spec
	echo -e "\nspec:\n" >> $CR_OUT
	tail -n +3 "$CHART_SRC/$NAME/values.yaml" | sed 's/^/  /' >> $CR_OUT
	yq w -i $CR_OUT kind $KIND
	echo -e "  Wrote CR to $CR_OUT"

	# Compute values we control
	OPERATOR_IMAGE="$QUAY_REPO/$NAME:$CHART_VERSION"

	# Write out CSV
	CSV_OUT="$ROOT_DIR/$NAME/$CSV_NAME.clusterserviceversion.yaml"
	cp "$ROOT_DIR/csv.template" $CSV_OUT
	echo -e "  Wrote CSV to $CSV_OUT"

	yq w -i $CSV_OUT metadata.name $CSV_NAME
	yq w -i $CSV_OUT metadata.annotations.alm-examples "["$(yq r --tojson $CR_OUT)"]"
	yq w -i $CSV_OUT metadata.annotations.categories "Helm"
	yq w -i $CSV_OUT metadata.annotations.description "$DESC"
	yq w -i $CSV_OUT metadata.annotations.containerImage $OPERATOR_IMAGE
	yq w -i $CSV_OUT metadata.annotations.createdAt $(date +"%Y-%m-%dT%H-%M-%SZ")
	yq w -i $CSV_OUT metadata.annotations.support $MAINTAINERS_NAME

	yq w -i $CSV_OUT spec.customresourcedefinitions.owned[0].name $NAME"s.charts.helm.k8s.io"
	yq w -i $CSV_OUT spec.customresourcedefinitions.owned[0].description "$DESC"
	yq w -i $CSV_OUT spec.customresourcedefinitions.owned[0].displayName $NAME
	yq w -i $CSV_OUT spec.customresourcedefinitions.owned[0].kind $KIND
	yq w -i $CSV_OUT spec.customresourcedefinitions.owned[0].version $API_VERSION

	yq w -i $CSV_OUT spec.displayName $NAME
	yq w -i $CSV_OUT spec.version $VERSION
	yq w -i $CSV_OUT spec.links[0].name "Helm Chart Source"
	yq w -i $CSV_OUT spec.links[0].url $SOURCE_LINK

	# Compute replaces CSV name
	if [ $REPLACES = true ]; then
		PREV_CSV="$NAME.v$REMOTE_VERSION"
		yq w -i $CSV_OUT spec.replaces $PREV_CSV
	fi

	yq w -i $CSV_OUT spec.maintainers[0].name $MAINTAINERS_NAME
	yq w -i $CSV_OUT spec.maintainers[0].email $MAINTAINERS_EMAIL

	# Build up deployment spec from SDK output
	yq w -i $CSV_OUT spec.install.spec.deployments[0].name "$NAME-operator"
	tail -n +5 "$TEMP_DIR/$NAME/deploy/operator.yaml" | sed 's/^/        /' >> $CSV_OUT
	yq w -i $CSV_OUT spec.install.spec.deployments[0].spec.template.spec.containers[0].image $OPERATOR_IMAGE
	yq w -i $CSV_OUT spec.install.spec.deployments[0].spec.template.spec.serviceAccountName "$NAME-operator"
	yq d -i $CSV_OUT spec.install.spec.deployments[0].spec.template.spec.containers[0].env
	yq w -i $CSV_OUT spec.install.spec.deployments[0].spec.template.spec.containers[0].env[+].name "WATCH_NAMESPACE"
	yq w -i $CSV_OUT spec.install.spec.deployments[0].spec.template.spec.containers[0].env[+].valueFrom.fieldRef.fieldPath "metadata.annotations['olm.targetNamespaces']"
	# Do some dumb find and replace because this yq thing can't make the structure I require
	sed -i -e 's/- valueFrom/  valueFrom/g' $CSV_OUT

	# Append generic RBAC config
	cat "$ROOT_DIR/rbac.template" | sed 's/^/      /' >> $CSV_OUT
	yq w -i $CSV_OUT spec.install.strategy "deployment"
	yq w -i $CSV_OUT spec.install.spec.permissions[+].serviceAccountName "$NAME-operator"
	yq w -i $CSV_OUT spec.install.spec.clusterPermissions[+].serviceAccountName "$NAME-operator"

	# Grab chart desc and append our special message
	echo -e "  description: |" >> $CSV_OUT
	echo -e "$DESC\n\n**Testing update**\n\n_This was generated from a Helm chart automatically._\n\nFind out more about this Chart at $SOURCE_LINK. Helm charts typically use conatiners that run as root. This Operator is granted a SecurityContextContraint to allow this.\n\n" | sed 's/^/    /' >> $CSV_OUT

	# Append icon base64 that is too long for yq to process
	if [[ ! -z "$ICON_SRC" ]] && [ "$ICON_SRC" = "null" ]; then
		echo "  No icon found in Chart.yaml"
	else
		case $ICON_SRC in
			*"png"*)
				FORMAT=png
				MIME=image/png
				;;
			*"gif"*)
				FORMAT=gif
				MIME=image/gif
				;;
			*"jpg"*)
				FORMAT=jpg
				MIME=image/jpeg
				;;
			*"svg"*)
				FORMAT=svg
				MIME=image/svg+xml
				;;
		esac

		echo "  Found icon $ICON_SRC"
		ICON_OUT="$ROOT_DIR/$NAME/icon.$FORMAT"
		echo -e "  icon:" >> $CSV_OUT
		curl -s $ICON_SRC > $ICON_OUT
		sips --resampleWidth 256 $ICON_OUT
		echo -e "  - base64data: "$(cat $ICON_OUT | openssl base64 -A) >> $CSV_OUT
		echo -e "    mediatype: $MIME" >> $CSV_OUT
	fi

	# Do some dumb find and replace because this yq thing can't make the structure I require
	sed -i -e 's/- serviceAccountName/  serviceAccountName/g' $CSV_OUT
	rm -r "$CSV_OUT-e"

	# Write out package
	PACKAGE_OUT="$ROOT_DIR/$1/$NAME.package.yaml"
	cp "$ROOT_DIR/package.template" $PACKAGE_OUT
	echo -e "  Wrote package to $PACKAGE_OUT"
	yq w -i $PACKAGE_OUT packageName $NAME
	yq w -i $PACKAGE_OUT packageName $NAME
	yq w -i $PACKAGE_OUT channels[0].currentCSV $CSV_NAME

	# Move out CRD
	CRD_OUT="$ROOT_DIR/$NAME/${NAME}.crd.yaml"
	cp "$TEMP_DIR/$NAME/deploy/crds/charts_${API_VERSION}_${NAME}_crd.yaml" $CRD_OUT

	# Write out bundle
	BUNDLE_OUT="$ROOT_DIR/$NAME/bundle.$VERSION.yaml"
	echo -e "data:" > $BUNDLE_OUT
	echo -e "  customResourceDefinitions: |-" >> $BUNDLE_OUT
	cat $CRD_OUT | sed 's/^/      /' >> $BUNDLE_OUT
	echo -e "  clusterServiceVersions: |-" >> $BUNDLE_OUT
	cat $CSV_OUT | sed 's/^/      /' >> $BUNDLE_OUT
	echo -e "  packages: |-" >> $BUNDLE_OUT
	cat $PACKAGE_OUT | sed 's/^/      /' >> $BUNDLE_OUT
	sed -i -e 's#  apiVersion: apiextensions.k8s.io/v1beta1#- apiVersion: apiextensions.k8s.io/v1beta1#g' $BUNDLE_OUT
	sed -i -e 's#  apiVersion: operators.coreos.com/v1alpha1#- apiVersion: operators.coreos.com/v1alpha1#g' $BUNDLE_OUT
	sed -i -e 's#  packageName:#- packageName:#g' $BUNDLE_OUT
	rm -r "$BUNDLE_OUT-e"

}

clean_sdks() {
	#rm -r "$TEMP_DIR"
	rm "$ICON_OUT"
}

push_image () {
	# push docker image for Operator
	docker tag "$QUAY_REPO/$NAME:latest" "$QUAY_REPO/$NAME:$CHART_VERSION"
	docker push "$QUAY_REPO/$NAME:$CHART_VERSION"
	# push bundle to Quay app registry
	"$ROOT_DIR/push-to-quay.sh" $NAME $VERSION "$ROOT_DIR/$NAME/bundle.$VERSION.yaml"
}

for filename in $(cat < "$WHITELIST"); do
    build_sdk "$filename"
    build_image "$filename"
    build_csv "$filename"
    push_image "$filename"
    clean_sdks "$filename"
done