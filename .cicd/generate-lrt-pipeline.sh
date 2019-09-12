#!/bin/bash
set -eo pipefail
. ./.cicd/helpers/general.sh
export MOJAVE_ANKA_TAG_BASE=${MOJAVE_ANKA_TAG_BASE:-'clean::cicd::git-ssh::nas::brew::buildkite-agent'}
export MOJAVE_ANKA_TEMPLATE_NAME=${MOJAVE_ANKA_TEMPLATE_NAME:-'10.14.4_6C_14G_40G'}
# Use files in platforms dir as source of truth for what platforms we need to generate steps for
export PLATFORMS_JSON_ARRAY='[]'
for FILE in $(ls $CICD_DIR/platforms); do
    # Ability to skip mac or linux by not even creating the json block
    ( [[ $SKIP_MAC == true ]] && [[ $FILE =~ 'macos' ]] ) && continue
    ( [[ $SKIP_LINUX == true ]] &&    [[ ! $FILE =~ 'macos' ]] ) && continue
    # Prevent using both platform files (only use unpinned or pinned)
    if [[ $PINNED == false || $UNPINNED == true ]] && [[ ! $FILE =~ 'macos' ]]; then
        export SKIP_CONTRACT_BUILDER=${SKIP_CONTRACT_BUILDER:-true}
        export SKIP_PACKAGE_BUILDER=${SKIP_PACKAGE_BUILDER:-true}
        [[ ! $FILE =~ 'unpinned' ]] && continue
    else
        [[ $FILE =~ 'unpinned' ]] && continue
    fi
    export FILE_NAME=$(echo $FILE | awk '{split($0,a,/\.(d|s)/); print a[1] }')
    export PLATFORM_NAME=$(echo $FILE_NAME | cut -d- -f1 | sed 's/os/OS/g')
    export PLATFORM_NAME_UPCASE=$(echo $PLATFORM_NAME | tr a-z A-Z)
    export VERSION_MAJOR=$(echo $FILE_NAME | cut -d- -f2 | cut -d. -f1)
    [[ $(echo $FILE_NAME | cut -d- -f2) =~ '.' ]] && export VERSION_MINOR="_$(echo $FILE_NAME | cut -d- -f2 | cut -d. -f2)" || export VERSION_MINOR=''
    export VERSION_FULL=$(echo $FILE_NAME | cut -d- -f2)
    OLDIFS=$IFS
    IFS="_"
    set $PLATFORM_NAME
    IFS=$OLDIFS
    export PLATFORM_NAME_FULL="$(capitalize $1)$( [[ ! -z $2 ]] && echo "_$(capitalize $2)" || true ) $VERSION_FULL"
    [[ $FILE_NAME =~ 'amazon' ]] && export ICON=':aws:'
    [[ $FILE_NAME =~ 'ubuntu' ]] && export ICON=':ubuntu:'
    [[ $FILE_NAME =~ 'centos' ]] && export ICON=':centos:'
    [[ $FILE_NAME =~ 'macos' ]] && export ICON=':darwin:'
    . $HELPERS_DIR/file-hash.sh $CICD_DIR/platforms/$FILE # returns HASHED_IMAGE_TAG, etc
    export PLATFORMS_JSON_ARRAY=$(echo $PLATFORMS_JSON_ARRAY | jq -c '. += [{ 
        "FILE_NAME": env.FILE_NAME, 
        "PLATFORM_NAME": env.PLATFORM_NAME,
        "PLATFORM_NAME_UPCASE": env.PLATFORM_NAME_UPCASE,
        "VERSION_MAJOR": env.VERSION_MAJOR,
        "VERSION_MINOR": env.VERSION_MINOR,
        "VERSION_FULL": env.VERSION_FULL,
        "PLATFORM_NAME_FULL": env.PLATFORM_NAME_FULL,
        "DOCKERHUB_FULL_TAG": env.FULL_TAG,
        "HASHED_IMAGE_TAG": env.HASHED_IMAGE_TAG,
        "ICON": env.ICON
        }]')
done
# Triggered LRT
if [[ ${BUILDKITE_PIPELINE_SLUG} == "eosio-lrt" ]]; then
    if [[ -z ${BUILDKITE_TRIGGERED_FROM_BUILD_ID} ]]; then
        export BUILD_SOURCE="--build \$BUILDKITE_BUILD_ID"
    fi
    export BUILD_SOURCE=${BUILD_SOURCE:---build \$BUILDKITE_TRIGGERED_FROM_BUILD_ID}
    export SKIP_UNIT_TESTS=${SKIP_UNIT_TESTS:-true}
    export SKIP_SERIAL_TESTS=${SKIP_SERIAL_TESTS:-true}
    export SKIP_LONG_RUNNING_TESTS=${SKIP_LONG_RUNNING_TESTS:-false}
    export SKIP_CONTRACT_BUILDER=true
    export SKIP_PACKAGE_BUILDER=true
fi
oIFS="$IFS"
IFS=$'' 
nIFS=$IFS # Needed to fix array splitting (\n won't work)
###################
# Anka Ensure Tag #
echo $PLATFORMS_JSON_ARRAY | jq -cr ".[]" | while read -r PLATFORM_JSON; do
    if [[ $(echo "$PLATFORM_JSON" | jq -r .FILE_NAME) =~ 'macos' ]]; then
    cat <<EOF
  - label: "$(echo "$PLATFORM_JSON" | jq -r .ICON) Anka - Ensure $(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_FULL) Template Dependency Tag"
    command:
      - "git clone git@github.com:EOSIO/mac-anka-fleet.git"
      - "cd mac-anka-fleet && . ./ensure_tag.bash -u 12 -r 25G -a '-n'"
    agents:
      - "queue=mac-anka-templater-fleet"
    env:
      REPO: ${BUILDKITE_PULL_REQUEST_REPO:-$BUILDKITE_REPO}
      REPO_COMMIT: $BUILDKITE_COMMIT
      TEMPLATE: $MOJAVE_ANKA_TEMPLATE_NAME
      TEMPLATE_TAG: $MOJAVE_ANKA_TAG_BASE
      PINNED: $PINNED
      UNPINNED: $UNPINNED
      TAG_COMMANDS: "git clone ${BUILDKITE_PULL_REQUEST_REPO:-$BUILDKITE_REPO} eos && cd eos && git checkout $BUILDKITE_COMMIT && git submodule update --init --recursive && export PINNED=$PINNED && export UNPINNED=$UNPINNED && . ./.cicd/platforms/macos-10.14.sh && cd ~/eos && cd .. && rm -rf eos"
      PROJECT_TAG: $(echo "$PLATFORM_JSON" | jq -r .HASHED_IMAGE_TAG)
    timeout: ${TIMEOUT:-320}
    skip: \${SKIP_$(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_UPCASE)_$(echo "$PLATFORM_JSON" | jq -r .VERSION_MAJOR)$(echo "$PLATFORM_JSON" | jq -r .VERSION_MINOR)}\${SKIP_ENSURE_$(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_UPCASE)_$(echo "$PLATFORM_JSON" | jq -r .VERSION_MAJOR)$(echo "$PLATFORM_JSON" | jq -r .VERSION_MINOR)}

EOF
    fi
done
echo "  - wait"; echo ""
###############
# BUILD STEPS #
echo $PLATFORMS_JSON_ARRAY | jq -cr ".[]" | while read -r PLATFORM_JSON; do
    if [[ ! $(echo "$PLATFORM_JSON" | jq -r .FILE_NAME) =~ 'macos' ]]; then
        cat <<EOF
  - label: "$(echo "$PLATFORM_JSON" | jq -r .ICON) $(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_FULL) - Build"
    command:
      - "./.cicd/build.sh"
      - "tar -pczf build.tar.gz build && buildkite-agent artifact upload build.tar.gz"
    env:
      IMAGE_TAG: $(echo "$PLATFORM_JSON" | jq -r .FILE_NAME)
      BUILDKITE_AGENT_ACCESS_TOKEN:
    agents:
      queue: "automation-eos-builder-fleet"
    timeout: ${TIMEOUT:-180}
    skip: \${SKIP_$(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_UPCASE)_$(echo "$PLATFORM_JSON" | jq -r .VERSION_MAJOR)$(echo "$PLATFORM_JSON" | jq -r .VERSION_MINOR)}${SKIP_BUILD}

EOF
    else
        cat <<EOF
  - label: "$(echo "$PLATFORM_JSON" | jq -r .ICON) $(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_FULL) - Build"
    command:
      - "git clone \$BUILDKITE_REPO eos && cd eos && git checkout \$BUILDKITE_COMMIT && git submodule update --init --recursive"
      - "cd eos && ./.cicd/build.sh"
      - "cd eos && tar -pczf build.tar.gz build && buildkite-agent artifact upload build.tar.gz"
    plugins:
      - chef/anka#v0.5.1:
          no-volume: true
          inherit-environment-vars: true
          vm-name: ${MOJAVE_ANKA_TEMPLATE_NAME}
          vm-registry-tag: "${MOJAVE_ANKA_TAG_BASE}::$(echo "$PLATFORM_JSON" | jq -r .HASHED_IMAGE_TAG)"
          modify-cpu: 12
          modify-ram: 24
          always-pull: true
          debug: true
          wait-network: true
    timeout: ${TIMEOUT:-180}
    agents:
      - "queue=mac-anka-large-node-fleet"
    skip: \${SKIP_$(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_UPCASE)_$(echo "$PLATFORM_JSON" | jq -r .VERSION_MAJOR)$(echo "$PLATFORM_JSON" | jq -r .VERSION_MINOR)}${SKIP_BUILD}

EOF
    fi
done
echo "  - wait"; echo ""
##############
# UNIT TESTS #
echo $PLATFORMS_JSON_ARRAY | jq -cr ".[]" | while read -r PLATFORM_JSON; do
    if [[ ! $(echo "$PLATFORM_JSON" | jq -r .FILE_NAME) =~ 'macos' ]]; then
        cat <<EOF
  - label: "$(echo "$PLATFORM_JSON" | jq -r .ICON) $(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_FULL) - Unit Tests"
    command:
      - "buildkite-agent artifact download build.tar.gz . --step '$(echo "$PLATFORM_JSON" | jq -r .ICON) $(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_FULL) - Build' && tar -xzf build.tar.gz"
      - "./.cicd/test.sh scripts/parallel-test.sh"
    env:
      IMAGE_TAG: $(echo "$PLATFORM_JSON" | jq -r .FILE_NAME)
      BUILDKITE_AGENT_ACCESS_TOKEN:
    agents:
      queue: "automation-eos-builder-fleet"
    timeout: ${TIMEOUT:-10}
    skip: \${SKIP_$(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_UPCASE)_$(echo "$PLATFORM_JSON" | jq -r .VERSION_MAJOR)$(echo "$PLATFORM_JSON" | jq -r .VERSION_MINOR)}${SKIP_UNIT_TESTS}

EOF
    else
        cat <<EOF
  - label: "$(echo "$PLATFORM_JSON" | jq -r .ICON) $(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_FULL) - Unit Tests"
    command:
      - "git clone \$BUILDKITE_REPO eos && cd eos && git checkout \$BUILDKITE_COMMIT && git submodule update --init --recursive"
      - "cd eos && buildkite-agent artifact download build.tar.gz . --step '$(echo "$PLATFORM_JSON" | jq -r .ICON) $(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_FULL) - Build' && tar -xzf build.tar.gz"
      - "cd eos && ./.cicd/test.sh scripts/parallel-test.sh"
    plugins:
      - chef/anka#v0.5.1:
          no-volume: true
          inherit-environment-vars: true
          vm-name: ${MOJAVE_ANKA_TEMPLATE_NAME}
          vm-registry-tag: "${MOJAVE_ANKA_TAG_BASE}::$(echo "$PLATFORM_JSON" | jq -r .HASHED_IMAGE_TAG)"
          always-pull: true
          debug: true
          wait-network: true
    timeout: ${TIMEOUT:-20}
    agents:
      - "queue=mac-anka-node-fleet"
    skip: \${SKIP_$(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_UPCASE)_$(echo "$PLATFORM_JSON" | jq -r .VERSION_MAJOR)$(echo "$PLATFORM_JSON" | jq -r .VERSION_MINOR)}${SKIP_UNIT_TESTS}

EOF
    fi
done
################
# SERIAL TESTS #
echo $PLATFORMS_JSON_ARRAY | jq -cr ".[]" | while read -r PLATFORM_JSON; do
    IFS=$oIFS
    SERIAL_TESTS=$(cat tests/CMakeLists.txt | grep nonparallelizable_tests | grep -v "^#" | awk -F" " '{ print $2 }')
    for TEST_NAME in $SERIAL_TESTS; do
        if [[ ! $(echo "$PLATFORM_JSON" | jq -r .FILE_NAME) =~ 'macos' ]]; then
            cat <<EOF
  - label: "$(echo "$PLATFORM_JSON" | jq -r .ICON) $(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_FULL) - $TEST_NAME"
    command:
      - "buildkite-agent artifact download build.tar.gz . --step '$(echo "$PLATFORM_JSON" | jq -r .ICON) $(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_FULL) - Build' && tar -xzf build.tar.gz"
      - "./.cicd/test.sh scripts/serial-test.sh $TEST_NAME"
    env:
      IMAGE_TAG: $(echo "$PLATFORM_JSON" | jq -r .FILE_NAME)
      BUILDKITE_AGENT_ACCESS_TOKEN:
    agents:
      queue: "automation-eos-builder-fleet"
    timeout: ${TIMEOUT:-20}
    skip: \${SKIP_$(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_UPCASE)_$(echo "$PLATFORM_JSON" | jq -r .VERSION_MAJOR)$(echo "$PLATFORM_JSON" | jq -r .VERSION_MINOR)}${SKIP_SERIAL_TESTS}

EOF
        else
            cat <<EOF
  - label: "$(echo "$PLATFORM_JSON" | jq -r .ICON) $(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_FULL) - $TEST_NAME"
    command:
      - "git clone \$BUILDKITE_REPO eos && cd eos && git checkout \$BUILDKITE_COMMIT && git submodule update --init --recursive"
      - "cd eos && buildkite-agent artifact download build.tar.gz . --step '$(echo "$PLATFORM_JSON" | jq -r .ICON) $(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_FULL) - Build' && tar -xzf build.tar.gz"
      - "cd eos && ./.cicd/test.sh scripts/serial-test.sh $TEST_NAME"
    plugins:
      - chef/anka#v0.5.1:
          no-volume: true
          inherit-environment-vars: true
          vm-name: ${MOJAVE_ANKA_TEMPLATE_NAME}
          vm-registry-tag: "${MOJAVE_ANKA_TAG_BASE}::$(echo "$PLATFORM_JSON" | jq -r .HASHED_IMAGE_TAG)"
          always-pull: true
          debug: true
          wait-network: true
    timeout: ${TIMEOUT:-20}
    agents:
      - "queue=mac-anka-node-fleet"
    skip: \${SKIP_$(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_UPCASE)_$(echo "$PLATFORM_JSON" | jq -r .VERSION_MAJOR)$(echo "$PLATFORM_JSON" | jq -r .VERSION_MINOR)}${SKIP_SERIAL_TESTS}
EOF
        fi
    done
    IFS=$nIFS
done
#############
# LRT TESTS #
echo $PLATFORMS_JSON_ARRAY | jq -cr ".[]" | while read -r PLATFORM_JSON; do
    IFS=$oIFS
    LR_TESTS=$(cat tests/CMakeLists.txt | grep long_running_tests | grep -v "^#" | awk -F" " '{ print $2 }')
    for TEST_NAME in $LR_TESTS; do
        if [[ ! $(echo "$PLATFORM_JSON" | jq -r .FILE_NAME) =~ 'macos' ]]; then
            cat <<EOF
  - label: "$(echo "$PLATFORM_JSON" | jq -r .ICON) $(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_FULL) - $TEST_NAME"
    command:
      - "buildkite-agent artifact download build.tar.gz . --step '$(echo "$PLATFORM_JSON" | jq -r .ICON) $(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_FULL) - Build' /${BUILD_SOURCE} && tar -xzf build.tar.gz"
      - "./.cicd/test.sh scripts/long-running-test.sh $TEST_NAME"
    env:
      IMAGE_TAG: $(echo "$PLATFORM_JSON" | jq -r .FILE_NAME)
      BUILDKITE_AGENT_ACCESS_TOKEN:
    agents:
      queue: "automation-eos-builder-fleet"
    timeout: ${TIMEOUT:-180}
    skip: \${SKIP_$(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_UPCASE)_$(echo "$PLATFORM_JSON" | jq -r .VERSION_MAJOR)$(echo "$PLATFORM_JSON" | jq -r .VERSION_MINOR)}${SKIP_LONG_RUNNING_TESTS:-true}

EOF
        else
            cat <<EOF
  - label: "$(echo "$PLATFORM_JSON" | jq -r .ICON) $(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_FULL) - $TEST_NAME"
    command:
      - "git clone \$BUILDKITE_REPO eos && cd eos && git checkout \$BUILDKITE_COMMIT && git submodule update --init --recursive"
      - "cd eos && buildkite-agent artifact download build.tar.gz . --step '$(echo "$PLATFORM_JSON" | jq -r .ICON) $(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_FULL) - Build' ${BUILD_SOURCE} && tar -xzf build.tar.gz"
      - "cd eos && ./.cicd/test.sh scripts/long-running-test.sh $TEST_NAME"
    plugins:
      - chef/anka#v0.5.1:
          no-volume: true
          inherit-environment-vars: true
          vm-name: ${MOJAVE_ANKA_TEMPLATE_NAME}
          vm-registry-tag: "${MOJAVE_ANKA_TAG_BASE}::$(echo "$PLATFORM_JSON" | jq -r .HASHED_IMAGE_TAG)"
          always-pull: true
          debug: true
          wait-network: true
    timeout: ${TIMEOUT:-180}
    agents:
      - "queue=mac-anka-node-fleet"
    skip: \${SKIP_$(echo "$PLATFORM_JSON" | jq -r .PLATFORM_NAME_UPCASE)_$(echo "$PLATFORM_JSON" | jq -r .VERSION_MAJOR)$(echo "$PLATFORM_JSON" | jq -r .VERSION_MINOR)}${SKIP_LONG_RUNNING_TESTS:-true}
EOF
        fi
    done
    IFS=$nIFS
done
###############
# TRIGGER LRT #
if [[ -z $BUILDKITE_TRIGGERED_FROM_BUILD_ID || $BUILDKITE_PIPELINE_SLUG != "eosio-lrt" ]]; then
    cat <<EOF
  - label: ":pipeline: Trigger LRTs"
    trigger: "eosio-lrt"
    build:
      message: "${BUILDKITE_MESSAGE}"
      commit: "${BUILDKITE_COMMIT}"
      branch: "${BUILDKITE_BRANCH}"
      env:
        BUILDKITE_PULL_REQUEST: "${BUILDKITE_PULL_REQUEST}"
        BUILDKITE_PULL_REQUEST_BASE_BRANCH: "${BUILDKITE_PULL_REQUEST_BASE_BRANCH}"
        BUILDKITE_PULL_REQUEST_REPO: "${BUILDKITE_PULL_REQUEST_REPO}"
        SKIP_BUILD: "true"

EOF
fi
cat <<EOF
  - wait:
    continue_on_failure: true

  - label: ":bar_chart: Test Metrics"
    command: |
      echo '+++ :compression: Extracting Test Metrics Code'
      tar -zxf .cicd/metrics/test-metrics.tar.gz
      echo '+++ :javascript: Running test-metrics.js'
      node --max-old-space-size=32768 test-metrics.js
    agents:
      queue: "automation-eos-builder-fleet"
    timeout: ${TIMEOUT:-10}
    soft_fail: true

  - wait

  - label: ":centos: CentOS 7.6 - Package Builder"
    command:
      - "buildkite-agent artifact download build.tar.gz . --step ':centos: CentOS 7.6 - Build' --agent-access-token \$\$BUILDKITE_AGENT_ACCESS_TOKEN && tar -xzf build.tar.gz"
      - "./.cicd/package.sh"
    env:
      IMAGE_TAG: "centos-7.6"
      BUILDKITE_AGENT_ACCESS_TOKEN:
      OS: "el7" # OS and PKGTYPE required for lambdas
      PKGTYPE: "rpm"
    agents:
      queue: "automation-eos-builder-fleet"
    timeout: ${TIMEOUT:-10}
    skip: ${SKIP_CENTOS_7_6}${SKIP_PACKAGE_BUILDER}${SKIP_LINUX}

  - label: ":ubuntu: Ubuntu 16.04 - Package Builder"
    command:
      - "buildkite-agent artifact download build.tar.gz . --step ':ubuntu: Ubuntu 16.04 - Build' --agent-access-token \$\$BUILDKITE_AGENT_ACCESS_TOKEN && tar -xzf build.tar.gz"
      - "./.cicd/package.sh"
    env:
      IMAGE_TAG: "ubuntu-16.04"
      BUILDKITE_AGENT_ACCESS_TOKEN:
      OS: "ubuntu-16.04" # OS and PKGTYPE required for lambdas
      PKGTYPE: "deb"
    agents:
      queue: "automation-eos-builder-fleet"
    timeout: ${TIMEOUT:-10}
    skip: ${SKIP_UBUNTU_16_04}${SKIP_PACKAGE_BUILDER}${SKIP_LINUX}

  - label: ":ubuntu: Ubuntu 18.04 - Package Builder"
    command:
      - "buildkite-agent artifact download build.tar.gz . --step ':ubuntu: Ubuntu 18.04 - Build' --agent-access-token \$\$BUILDKITE_AGENT_ACCESS_TOKEN && tar -xzf build.tar.gz"
      - "./.cicd/package.sh"
    env:
      IMAGE_TAG: "ubuntu-18.04"
      BUILDKITE_AGENT_ACCESS_TOKEN:
      OS: "ubuntu-18.04" # OS and PKGTYPE required for lambdas
      PKGTYPE: "deb"
    agents:
      queue: "automation-eos-builder-fleet"
    timeout: ${TIMEOUT:-10}
    skip: ${SKIP_UBUNTU_18_04}${SKIP_PACKAGE_BUILDER}${SKIP_LINUX}

  - label: ":darwin: macOS 10.14 - Package Builder"
    command:
      - "git clone \$BUILDKITE_REPO eos && cd eos && git checkout \$BUILDKITE_COMMIT"
      - "cd eos && buildkite-agent artifact download build.tar.gz . --step ':darwin: macOS 10.14 - Build' && tar -xzf build.tar.gz"
      - "cd eos && ./.cicd/package.sh"
    plugins:
      - chef/anka#v0.5.1:
          no-volume: true
          inherit-environment-vars: true
          vm-name: 10.14.4_6C_14G_40G
          vm-registry-tag: "clean::cicd::git-ssh::nas::brew::buildkite-agent"
          always-pull: true
          debug: true
          wait-network: true
    agents:
      - "queue=mac-anka-node-fleet"
    timeout: ${TIMEOUT:-10}
    skip: ${SKIP_MACOS_10_14}${SKIP_PACKAGE_BUILDER}${SKIP_MAC}

  - label: ":ubuntu: Ubuntu 18.04 - Contract Builder"
    command: "./.cicd/installation-build.sh"
    env:
      IMAGE_TAG: "ubuntu-18.04-unpinned"
      BUILDKITE_AGENT_ACCESS_TOKEN:
    agents:
      queue: "automation-eos-builder-fleet"
    timeout: ${TIMEOUT:-30}
    skip: ${SKIP_CONTRACT_BUILDER}${SKIP_LINUX}

  - wait

  - label: ":git: Git Submodule Regression Check"
    command: "./.cicd/submodule-regression-check.sh"
    agents:
      queue: "automation-basic-builder-fleet"
    timeout: ${TIMEOUT:-5}

  - label: ":beer: Brew Updater"
    command: |
      buildkite-agent artifact download eosio.rb . --step ':darwin: macOS 10.14 - Package Builder'
      buildkite-agent artifact upload eosio.rb
    agents:
      queue: "automation-basic-builder-fleet"
    timeout: "${TIMEOUT:-5}"
    skip: ${SKIP_PACKAGE_BUILDER}${SKIP_MAC}${SKIP_MACOS_10_14}

EOF
IFS=$oIFS