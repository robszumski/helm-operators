#!/bin/bash

echo -e "\nParsing Whitelist:"

# Settings
WHITELIST="whitelist.yaml"
CHART_SRC="/Users/robszumski/Documents/charts/stable"
SDK="/Users/robszumski/Documents/src/github.com/operator-framework/operator-sdk/build/operator-sdk-pr-949"
QUAY_REPO="quay.io/helmoperators"
ROOT_DIR="$PWD"

build_sdk() {
	echo -e "\nBuilding SDK for: $1 ($CHART_SRC/$1)"
	cd $ROOT_DIR
	$SDK new $1 --type=helm --helm-chart-source="$CHART_SRC/$1"
}

build_image() {
	cd $1
	$SDK build "$QUAY_REPO/$1"
	docker build "$QUAY_REPO/$1"
}

build_csv() {
	echo -e "\nBuilding CSV for: $1"

	# Fetch info from Chart
	NAME=$1
	VERSION=$(yq r $CHART_SRC/$1/Chart.yaml version)
	CSV_NAME="$1.v$VERSION"
	SOURCE_LINK=$(yq r $CHART_SRC/$1/Chart.yaml sources[0])
	ICON_SRC=$(yq r $CHART_SRC/$1/Chart.yaml icon)
	MAINTAINERS_NAME=$(yq r $CHART_SRC/$1/Chart.yaml maintainers[0].name)
	MAINTAINERS_EMAIL=$(yq r $CHART_SRC/$1/Chart.yaml maintainers[0].email)
	DESC=$(yq r $CHART_SRC/$1/Chart.yaml description)
	API_VERSION="v1alpha1"
	KIND=$(echo $NAME |  head -c 1 | tr [a-z] [A-Z]; echo $NAME | tail -c +2)

	# Write out CR metadata
	CR_OUT="$ROOT_DIR/$1/$NAME.cr.yaml"
	cp "$ROOT_DIR/cr.template" $CR_OUT

	# Grab default values, indent them, and append to CR spec
	echo -e "\nspec:\n" >> $CR_OUT
	tail -n +3 "$CHART_SRC/$1/values.yaml" | sed 's/^/  /' >> $CR_OUT
	yq w -i $CR_OUT kind $KIND
	echo -e "  Wrote CR to $CR_OUT"

	# Compute values we control
	OPERATOR_IMAGE="$QUAY_REPO/$NAME:$VERSION"

	# Write out CSV
	CSV_OUT="$ROOT_DIR/$1/$CSV_NAME.clusterserviceversion.yaml"
	cp "$ROOT_DIR/csv.template" $CSV_OUT
	echo -e "  Wrote CSV to $CSV_OUT"

	yq w -i $CSV_OUT metadata.name $CSV_NAME
	yq w -i $CSV_OUT metadata.annotations.alm-examples "["$(yq r --tojson $CR_OUT)"]"
	yq w -i $CSV_OUT metadata.annotations.categories "Helm"
	yq w -i $CSV_OUT metadata.annotations.description $DESC
	yq w -i $CSV_OUT metadata.annotations.containerImage $OPERATOR_IMAGE
	yq w -i $CSV_OUT metadata.annotations.createdAt $(date +"%Y-%m-%dT%H-%M-%SZ")
	yq w -i $CSV_OUT metadata.annotations.support $MAINTAINERS_NAME

	yq w -i $CSV_OUT spec.customresourcedefinitions.owned[0].name $NAME"s.charts.helm.k8s.io"
	yq w -i $CSV_OUT spec.customresourcedefinitions.owned[0].description $DESC
	yq w -i $CSV_OUT spec.customresourcedefinitions.owned[0].displayName $NAME
	yq w -i $CSV_OUT spec.customresourcedefinitions.owned[0].kind $KIND
	yq w -i $CSV_OUT spec.customresourcedefinitions.owned[0].version $API_VERSION

	yq w -i $CSV_OUT spec.displayName $NAME
	yq w -i $CSV_OUT spec.version $VERSION
	yq w -i $CSV_OUT spec.links[0].name "Helm Chart Source"
	yq w -i $CSV_OUT spec.links[0].url $SOURCE_LINK

	yq w -i $CSV_OUT spec.maintainers[0].name $MAINTAINERS_NAME
	yq w -i $CSV_OUT spec.maintainers[0].email $MAINTAINERS_EMAIL

	# Build up deployment spec from SDK output
	yq w -i $CSV_OUT spec.install.spec.deployments[0].name "$NAME-operator"
	tail -n +5 "$ROOT_DIR/$1/deploy/operator.yaml" | sed 's/^/        /' >> $CSV_OUT
	yq w -i $CSV_OUT spec.install.spec.deployments[0].spec.template.spec.containers[0].image $OPERATOR_IMAGE
	yq w -i $CSV_OUT spec.install.spec.deployments[0].spec.template.spec.serviceAccountName "$NAME-operator"

	# Append generic RBAC config
	cat "$ROOT_DIR/rbac.template" | sed 's/^/      /' >> $CSV_OUT
	yq w -i $CSV_OUT spec.install.strategy "deployment"
	yq w -i $CSV_OUT spec.install.spec.permissions[+].serviceAccountName "$NAME-operator"
	yq w -i $CSV_OUT spec.install.spec.clusterPermissions[+].serviceAccountName "$NAME-operator"

	# Grab chart desc and append our special message
	echo -e "  description: |" >> $CSV_OUT
	echo -e "$DESC\n\n_This was generated from a Helm chart automatically._\n\nMany Helm charts require running a root, your admin will need to allow this with a SecurityContextConstraint." | sed 's/^/    /' >> $CSV_OUT

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
	cp "$ROOT_DIR/$NAME/deploy/crds/charts_${API_VERSION}_${NAME}_crd.yaml" $CRD_OUT

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
	rm -r "$ROOT_DIR/$NAME/build"
	rm -r "$ROOT_DIR/$NAME/deploy"
	rm -r "$ROOT_DIR/$NAME/helm-charts"
	rm -rf "$ROOT_DIR/$NAME/.git/"
	rm "$ROOT_DIR/$NAME/watches.yaml"
	rm "$ICON_OUT"
}

push_image () {
	# push docker image for Operator
	docker tag "$QUAY_REPO/$NAME:latest" "$QUAY_REPO/$NAME:$VERSION"
	docker push "$QUAY_REPO/$NAME:$VERSION"
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