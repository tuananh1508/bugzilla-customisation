#!/bin/bash
set -e

echo "START $0 $(date)"
STAGE=dev

# Usage info
show_help() {
cat << EOF
Usage: ${0##*/} [-p]
By default, deploy to dev environment on AWS account 812644853088
	-p          PRODUCTION 192458993663
	-d          DEMO 915001051872
EOF
}

while getopts "pd" opt
do
	case $opt in
		p)
			echo "PRODUCTION" >&2
			STAGE=prod
			;;
		d)
			echo "DEMO" >&2
			STAGE=demo
			;;
		*)
			show_help >&2
			exit 1
			;;
	esac
done
AWS_PROFILE=uneet-$STAGE
echo $AWS_PROFILE
shift "$((OPTIND-1))"   # Discard the options and sentinel --

export COMMIT=$(git rev-parse --short HEAD)

# Run deploy hooks
for hook in deploy-hooks/*
do
	[[ -x $hook ]] || continue
	if "$hook"
	then
		echo OK: "$hook"
	else
		echo FAIL: "$hook"
		exit 1
	fi
done

if ! aws configure --profile $AWS_PROFILE list
then
	echo Profile $AWS_PROFILE does not exist >&2

	if ! test "$AWS_ACCESS_KEY_ID"
	then
		echo Missing $AWS_ACCESS_KEY_ID >&2
		exit 1
	fi

	echo Attempting to setup one from the environment >&2
	aws configure set profile.uneet-${STAGE}.aws_access_key_id $AWS_ACCESS_KEY_ID
	aws configure set profile.uneet-${STAGE}.aws_secret_access_key $AWS_SECRET_ACCESS_KEY
	aws configure set profile.uneet-${STAGE}.region ap-southeast-1

	if ! aws configure --profile $AWS_PROFILE list
	then
		echo Profile $AWS_PROFILE does not exist >&2
		exit 1
	fi

fi

if ! hash ecs-cli
then
	echo Please install https://github.com/aws/amazon-ecs-cli and ensure it is in your \$PATH
	echo curl -o /usr/local/bin/ecs-cli https://s3.amazonaws.com/amazon-ecs-cli/ecs-cli-linux-amd64-latest && chmod +x /usr/local/bin/ecs-cli
	exit 1
else
	ecs-cli -version
fi

ecs-cli configure --cluster unee-t-ins --region ap-southeast-1 --compose-service-name-prefix ecscompose-service-
test -f aws-env.$STAGE && source aws-env.$STAGE

service=$(grep -A1 services AWS-docker-compose.yml | tail -n1 | tr -cd '[[:alnum:]]')
echo Deploying $service with commit $COMMIT >&2

# Ensure docker compose file's STAGE env is empty for production
test "$STAGE" == prod && export STAGE=""

envsubst < AWS-docker-compose.yml > docker-compose-${service}.yml

ecs-cli compose --aws-profile $AWS_PROFILE -p ${service} -f docker-compose-${service}.yml service up \
	--deployment-max-percent 100 \
	--deployment-min-healthy-percent 50 \
	--timeout 7

ecs-cli compose --aws-profile $AWS_PROFILE -p ${service} -f docker-compose-${service}.yml service ps

echo "END $0 $(date)"