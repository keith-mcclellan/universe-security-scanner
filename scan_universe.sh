mkdir -p scan-results
cd scan-results

for i in `dcos package search | awk '{ print $1 }' | grep '^[[:lower:]]'`; do dcos package describe $i | jq -er .package.resource.assets.container.docker | awk -F'":' '{print $2}' | sed -e 's/ "//g' -e 's/"$//' | sed '/^\s*$/d' | sed '/^docker\.io\//d'; done >>universe_containers.txt

for i in `cat universe_containers.txt`; do echo $i && docker run --env-file=../klar-env-file keithmcclellan/klar $i | cat &> ${i//\//_}.vuln ; done
