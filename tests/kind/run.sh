#!/usr/bin/env bash

#
# -a: force re-answering all questions
# -f <profile>: force re-answering for given profile
# -s: guidebook store root
# -b: run this guidebook
# -i: don't use kind; this is helpful when testing inside of a kubernetes cluster
#

set -e
set -o pipefail

SCRIPTDIR=$(cd $(dirname "$0") && pwd)
. "$SCRIPTDIR"/values.sh

while getopts "ab:f:is:" opt
do
    case $opt in
        a) FORCE_ALL=true; continue;;
        f) FORCE=$OPTARG; continue;;
        s) export GUIDEBOOK_STORE=$OPTARG; echo "Using store=$GUIDEBOOK_STORE"; continue;;
        b) GUIDEBOOK=$OPTARG; continue;;
        i) NO_KIND=true; continue;;
        *) continue;;
    esac
done
shift $((OPTIND-1))

if [ -z "$NO_KIND" ]; then
    export KUBECONFIG=$("$SCRIPTDIR"/setup.sh)
    echo "Using KUBECONFIG=$KUBECONFIG"
fi

# We get this for free from github actions. Add it generally. This
# informs the guidebooks to adjust their resource demands.
export CI=true

# build docker image of log aggregator just for this test and load it
# into kind
function build {
    export LOG_AGGREGATOR_IMAGE=codeflare-log-aggregator:test
    FAST=true npm run build:docker:logs
    kind load docker-image $LOG_AGGREGATOR_IMAGE --name $CLUSTER
}

#
# !!!! This is the main work of the test !!!!
#
# - launch bin/codeflare -p $profile against the $guidebook
# - it is up to the caller to validate the output of this command,
#   e.g. by looking for "succeeded" (see below)
#
function run {
    local profileFull=$1
    local variant=$(dirname $profileFull)
    local profile=$(basename $profileFull)
    export MWPROFILES_PATH="$MWPROFILES_PATH_BASE"/$variant
    mkdir -p "$MWPROFILES_PATH"

    local guidebook=${2-$GUIDEBOOK}
    local yes=$([ -z "$FORCE_ALL" ] && [ "$FORCE" != "$profileFull" ] && [ -f "$MWPROFILES_PATH/$profile" ] && echo "--yes" || echo "")

    local PRE="$MWPROFILES_PATH_BASE"/../profiles.d/$profile/pre
    if [ -f "$PRE" ]; then
        echo "Running pre guidebooks for profile=$profile"
        cat "$PRE" | xargs -n1 "$ROOT"/bin/codeflare -p $profile $yes
    fi

    echo "Running with variant=$variant profile=$profile yes=$yes"
    "$ROOT"/bin/codeflare -V -p $profile $yes $guidebook
}

# Undeploy any prior log aggregator
function cleanup {
    local profileFull=$1
    local variant=$(dirname $profileFull)
    local profile=$(basename $profileFull)
    export MWPROFILES_PATH="$MWPROFILES_PATH_BASE"/$variant

    echo "Undeploying any prior log aggregator"
    ("$ROOT"/bin/codeflare -p $profile -y ml/ray/aggregator/in-cluster/client-side/undeploy \
         || exit 0)
}

#
# Attach a log aggregator
# - $1: variant/profile e.g. non-gpu1/keep-it-simple
# - $2: JOB_ID
#
function attach {
    local profileFull=$1
    local variant=$(dirname $profileFull)
    local profile=$(basename $profileFull)
    export MWPROFILES_PATH="$MWPROFILES_PATH_BASE"/$variant

    local jobId=$2

    echo "Attaching variant=$variant profile=$profile jobId=$jobId"
    "$ROOT"/bin/codeflare -V -p $profile attach -a $jobId
}

# @return path to locally captured logs for the given jobId, run in the given profile
function localpath {
    local profile=$1
    local jobId=$2

    local BASE=$(node -e "import('madwizard/dist/profiles/index.js').then(_ => _.guidebookJobDataPath({ profile: \"$profile\" })).then(console.log)")
    echo "$BASE/$jobId"
}

# Validate the output of the log aggregator
function validateAttach {
    local profileFull=$1
    local variant=$(dirname $profileFull)
    local profile=$(basename $profileFull)
    export MWPROFILES_PATH="$MWPROFILES_PATH_BASE"/$variant

    local jobId=$2

    RUNDIR=$(localpath $profile $jobId)

    if [ ! -d "$RUNDIR" ]; then
        echo "❌ Logs were not captured locally: missing logdir"
        exit 1
    elif [ ! -f "$RUNDIR/jobid.txt" ]; then
        echo "❌ Logs were not captured locally: missing jobid.txt"
        exit 1
    elif [ ! -f "$RUNDIR/logs/job.txt" ]; then
        echo "❌ Logs were not captured locally: missing logs/job.txt"
        exit 1
    elif [ ! -s "$RUNDIR/logs/job.txt" ]; then
        echo "❌ Logs were not captured locally: empty logs/job.txt"
        exit 1
    fi

    # TODO the expected output is going to be profile-specific
    grep -q 'Final result' "$RUNDIR/logs/job.txt" \
        && echo "✅ Logs seem good!" \
            || (echo "❌ Logs were not captured locally: job logs incomplete" && exit 1)
}

function logpoller {
    sleep 10
    while true; do
        kubectl logs -l $1 -f
        sleep 3
    done
}

#
# clean up after ourselves before we exit
#
function onexit {
    if [ -n "$HEAD_POLLER_PID" ]; then
        (kill $HEAD_POLLER_PID || exit 0)
    fi
    if [ -n "$WORKER_POLLER_PID" ]; then
        (kill $WORKER_POLLER_PID || exit 0)
    fi
    if [ -n "$EVENTS_PID" ]; then
        (kill $EVENTS_PID || exit 0)
    fi
    if [ -n "$AGGREGATOR_POLLER_PID" ]; then
        (kill $AGGREGATOR_POLLER_PID || exit 0)
    fi
}

#
# stream out logs, if we were asked to do so (via `DEBUG_KUBERNETES=1`)
#
function debug {
    if [ -n "$DEBUG_KUBERNETES" ]; then
        logpoller ray-node-type=head &
        HEAD_POLLER_PID=$!

        logpoller ray-node-type=worker &
        WORKER_POLLER_PID=$!

        logpoller app=guidebook-log-aggregator &
        AGGREGATOR_POLLER_PID=$!

        kubectl get events -w &
        EVENTS_PID=$!
    fi
}

#
# This is the heart of the test.
#
#   - 1. `run` fires off a run; capture the output to $OUTPUT file
#   - 2. fire of log aggregator
#   - 3. validate log aggregator output
#   - 4. validate job output
#
function test {
    OUTPUT=$(mktemp)

    # allocate JOB_ID (requires node and `uuid` npm; but we should
    # have both for codeflare-cli dev)
    export JOB_ID=$(node -e 'console.log(require("uuid").v4())')
    echo "Using JOB_ID=$JOB_ID"

    # 1. launch codeflare guidebook run
    run "$1" | tee $OUTPUT &
    RUN_PID=$!

    # 2. if asked, attach a log aggregator
    if [ -n "$TEST_LOG_AGGREGATOR" ]; then
        cleanup "$1"

        # wait to attach until the job has been submitted
        # while true; do
        #     grep -q 'submitted successfully' "$OUTPUT" && break
        #     sleep 1
        # done
        sleep 10

        echo "About to attach"
        attach "$1" "$JOB_ID"
    fi

    wait $RUN_PID
    # the job should be done now

    # 3. if asked, now validate the log aggregator
    if [ -n "$TEST_LOG_AGGREGATOR" ]; then
        # TODO validate run status in captured logs; should be SUCCESSFUL
        validateAttach "$1" "$JOB_ID"
    fi
    
    # 4. validate the output of the job itself
    grep succeeded $OUTPUT
}

trap onexit INT
trap onexit EXIT

build
debug
test "$1"
