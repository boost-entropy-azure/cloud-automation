#!/bin/bash


source "${GEN3_HOME}/gen3/lib/utils.sh"
gen3_load "gen3/gen3setup"


# lib -----------------------------------

# Creates a bucket manifest as a input for s3 batch job
# The manifest contains bucket and key only
#
# @param source_bucket
# @param manifest_bucket
#
gen3_create_manifest() {
  local source_bucket=$1
  local manifest_bucket=$2
  if [[ -f $WORKSPACE/tempKeyFile ]]; then
    gen3_log_info "previous key file found. Deleting"
    rm $WORKSPACE/tempKeyFile
  fi
  aws s3api --profile fence_bot list-objects --bucket "$source_bucket" --query 'Contents[].{Key: Key}' | jq -r '.[].Key' >> "$WORKSPACE/tempKeyFile"
  if [[ -f $WORKSPACE/manifest.csv ]]; then
    rm $WORKSPACE/manifest.csv
  fi
  while read line; do
    echo "$source_bucket,$line" >> $WORKSPACE/manifest.csv
  done<$WORKSPACE/tempKeyFile
  rm $WORKSPACE/tempKeyFile
  if [[ ! -z $3 ]]; then
    gen3_aws_run aws s3 cp $WORKSPACE/manifest.csv s3://"$manifest_bucket" --profile $3
  else
    gen3_aws_run aws s3 cp $WORKSPACE/manifest.csv s3://"$manifest_bucket"
  fi
  rm $WORKSPACE/manifest.csv
}


####### IAM part

# function to check if role/policy exists
## if no role call create role
## if no policy create policy, if policy modify policy to support new endpoints
#
# @param source_bucket
# @param manifest_bucket
#
initialization() {

  source_bucket=$1
  manifest_bucket=$2  

  ####### Create lambda-generate-metadata role ################
  if [[ -z $(gen3_aws_run aws iam list-roles | jq -r .Roles[].RoleName | grep lambda-generate-metadata) ]]; then
    gen3_log_info " Creating lambda-generate-metadata role ...."
    gen3_aws_run aws iam create-role --role-name lambda-generate-metadata --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [
        {
          "Effect": "Allow",
          "Principal": {
          "Service": "lambda.amazonaws.com"
          },
          "Action": "sts:AssumeRole"
        }
        ]
    }'
    if [ ! $? == 0 ]; then
        gen3_log_info " Can not create lambda-generate-metadata role"
        exit 1
    fi
    sleep 5
  else
    gen3_log_info "lambda-generate-metadata role already exist"
  fi

  aws iam put-role-policy \
  --role-name lambda-generate-metadata \
  --policy-name LambdaMetadataJobPolicy \
  --policy-document '{
   "Version":"2012-10-17",
  "Statement":[
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::'${source_bucket}'/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::'${manifest_bucket}'/*"
      ]
    }
  ]
}'

  if [ ! $? == 0 ]; then
      gen3_log_info " Can update role policy for s3-batch-operation role"
      exit 1
  fi

  if [[ -z $(gen3_aws_run aws lambda list-functions | jq -r .Functions[].FunctionName | grep object-metadata-compute) ]]; then
    gen3_log_info " Creating lambda function ...."
    role_arn=$(gen3_aws_run aws iam get-role --role-name lambda-generate-metadata | jq -r .Role.Arn)
    gen3 awslambda create object-metadata-compute "function to compute object metadata" $role_arn
    if [ ! $? == 0 ]; then
      gen3_log_info "Can not create lambda function"
      exit 1
    else
      gen3_log_info "Successfully create lambda function"
    fi
    sleep 10
  else
    gen3_log_info "Lambda function object-metadata-compute already exists"
  fi

  local access_key=$(gen3 secrets decode fence-config fence-config.yaml | yq -r .AWS_CREDENTIALS.fence_bot.aws_access_key_id)
  local secret_key=$(gen3 secrets decode fence-config fence-config.yaml | yq -r .AWS_CREDENTIALS.fence_bot.aws_secret_access_key)
  aws lambda update-function-configuration --function-name object-metadata-compute \
  --environment "Variables={ACCESS_KEY_ID=$access_key,SECRET_ACCESS_KEY=$secret_key}"

  if [[ -z $(gen3_aws_run aws iam list-roles | jq -r .Roles[].RoleName | grep s3-batch-operation) ]]; then
    gen3_log_info "Creating s3-batch-operation role"
    gen3_aws_run aws iam create-role --role-name s3-batch-operation --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [
        {
          "Effect": "Allow",
          "Principal": {
          "Service": "batchoperations.s3.amazonaws.com"
          },
          "Action": "sts:AssumeRole"
        }
        ]
    }'
    if [ ! $? == 0 ]; then
      gen3_log_info " Can not create s3-batch-operation role"
      exit 1
    fi
    sleep 5
  else
    gen3_log_info "s3-batch-operation role already exist"
  fi

  local lambda_arn=$(gen3_aws_run aws lambda get-function --function-name object-metadata-compute | jq -r .Configuration.FunctionArn)

  gen3_aws_run aws iam put-role-policy \
  --role-name  s3-batch-operation\
  --policy-name s3-batch-operation-policy \
  --policy-document '{
  "Version":"2012-10-17",
  "Statement":[
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::'${manifest_bucket}'/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": "lambda:InvokeFunction",
      "Resource": "'${lambda_arn}'"
    }
  ]
}'
  if [ ! $? == 0 ]; then
      gen3_log_info " Can update role policy for 3-batch-operation role"
      exit 1
  fi

}

# function to create job
# creates job and returns command to check job status after completed
#
# @param source_bucket
# @param manifest_bucket
#
gen3_bucket_manifest_create_job() {
  local manifest_bucket=$2
  echo "manifest bucket" ${manifest_bucket}
  local lambda_arn=$(gen3_aws_run aws lambda get-function --function-name object-metadata-compute | jq -r .Configuration.FunctionArn)
  local accountId=$(gen3_aws_run aws iam get-role --role-name s3-batch-operation | jq -r .Role.Arn |cut -d : -f 5)
  local etag=$(gen3_aws_run aws s3api list-objects --bucket ${manifest_bucket} --output json --query '{Name: Contents[].{Key: ETag}}' --prefix manifest.csv | jq -r .Name[].Key | sed -e 's/"//g')
  local OPERATION='{"LambdaInvoke": { "FunctionArn": "'${lambda_arn}'" } }'
  local MANIFEST='{"Spec": {"Format": "S3BatchOperations_CSV_20180820","Fields": ["Bucket","Key"]},"Location": {"ObjectArn": "arn:aws:s3:::'${manifest_bucket}'/manifest.csv","ETag": "'$etag'"}}'
  local REPORT='{"Bucket": "arn:aws:s3:::'${manifest_bucket}'","Format": "Report_CSV_20180820","Enabled": true,"Prefix": "reports/object_metadata","ReportScope": "AllTasks"}'
  local roleArn=$(gen3_aws_run aws iam get-role --role-name s3-batch-operation | jq -r .Role.Arn)
  status=$(gen3_aws_run aws s3control create-job --account-id "$accountId" --manifest "${MANIFEST//$'\n'}" --operation "${OPERATION//$'\n'/}" --report "${REPORT//$'\n'}" --priority 10 --role-arn $roleArn --client-request-token "$(uuidgen)" --region us-east-1 --description "Copy with Replace Metadata" --no-confirmation-required)
  echo $status
}

# function to check job status
#
# @param job-id
#
gen3_manifest_generating_status() {
  if [[ $# -lt 1 ]]; then
    gen3_log_info "The job id is required "
    exit 1
  fi  

  local jobId=$1
  local accountId=$(gen3_aws_run aws iam get-role --role-name s3-batch-operation --region us-east-1 | jq -r .Role.Arn | cut -d : -f 5)
  local status=$(gen3_aws_run aws s3control describe-job --account-id $accountId --job-id $jobId --region us-east-1 | jq -r .Job.Status)
  while [[ $status != 'Complete' ]] || [[ $counter > 90 ]]; do
    gen3_log_info "Waiting for job to complete. Current status $status"
    local status=$(gen3_aws_run aws s3control describe-job --account-id $accountId --job-id $jobId --region us-east-1 | jq -r .Job.Status)
    sleep 10      
  done
  echo $status
  echo $(gen3_aws_run aws s3control describe-job --account-id $accountId --job-id $jobId --region us-east-1 | jq -r .Job.ProgressSummary)
}

# Creates a S3 batch job
#
# @param source_bucket
# @param manifest_bucket
#
gen3_manifest_generating() {
  if [[ $# -lt 2 ]]; then
    gen3_log_info "The input and manifest buckets are required "
    exit 1
  fi
  gen3_create_manifest $@
  initialization $@
  if [ ! $? == 0 ]; then
      gen3_log_info "Intialization failed!!!"
      exit 1
  fi
  gen3_bucket_manifest_create_job $@
}

# Delete all roles, policies and lambda function

gen3_manifest_generating_cleanup() {
  gen3_aws_run aws iam delete-role-policy --role-name lambda-generate-metadata --policy-name LambdaMetadataJobPolicy
  gen3_aws_run aws iam delete-role --role-name lambda-generate-metadata
  gen3_aws_run aws lambda delete-function --function-name object-metadata-compute
  gen3_aws_run aws iam delete-role-policy --role-name s3-batch-operation --policy-name  s3-batch-operation-policy
  gen3_aws_run aws iam delete-role  --role-name s3-batch-operation

}

# Show help

gen3_bucket_manifest_help() {
  gen3 help bucket-manifest
}

# Parse the report manifest to create the output manifest
#
# @param report_file
# @param output_manifest_file
#
write_to_file() {
  while IFS= read -r line
  do
    local bucket=$(echo $line | cut -d ',' -f1)
    local key=$(echo $line | cut -d ',' -f2)
    res=$(echo $line | cut -d ',' -f7-8)
    ok=$(echo $line | cut -d ',' -f4)
    if [[ $ok == 'succeeded' ]]; then
      md5=$(echo $res | sed 's/"{/{/g' | sed 's/}"/}/g' | sed 's/""/"/g' | jq -r .md5)
      size=$(echo $res | sed 's/"{/{/g' | sed 's/}"/}/g' | sed 's/""/"/g' | jq -r .size)
    else
      md5=$res  
      size=""
    fi
    echo "$bucket,$key,$size,$md5" >> $2
  done < "$1"
}

# Get output manifest of a S3 batch job 
#
# @param job-id
#
gen3_get_output_manifest() {
  if [[ $# -lt 1 ]]; then
    gen3_log_info "The job id is required "
    exit 1
  fi  
  local jobId=$1
  local accountId=$(gen3_aws_run aws iam get-role --role-name s3-batch-operation --region us-east-1 | jq -r .Role.Arn | cut -d : -f 5)
  local report=$(gen3_aws_run aws s3control describe-job --account-id $accountId --job-id $jobId --region us-east-1 | jq -r .Job.Report)
  local bucket=$(echo $report | jq -r .Bucket | cut -d ':' -f6)
  local prefix=$(echo $report | jq -r .Prefix)
  
  gen3_aws_run aws s3 cp s3://$bucket/$prefix/job-$jobId/manifest.json $XDG_RUNTIME_DIR/
  if [ ! $? == 0 ]; then
    gen3_log_info "Can not find the output manifest.json"
  else
    if [[ -f $WORKSPACE/output.tsv ]]; then
      rm $WORKSPACE/output.tsv
    fi

    local content=$(<$XDG_RUNTIME_DIR/manifest.json)
    echo $content | jq -r .Results | jq .
    local key=$(echo $content | jq -r .Results[0].Key)
    gen3_aws_run aws s3 cp s3://$bucket/$key $XDG_RUNTIME_DIR/output.txt
    write_to_file $XDG_RUNTIME_DIR/output.txt $WORKSPACE/output.tsv

    key=$(echo $content | jq -r .Results[1].Key)
    if [ ! -n "${key}" ]; then
      gen3_aws_run aws s3 cp s3://$bucket/$key $XDG_RUNTIME_DIR/output.txt
      write_to_file $XDG_RUNTIME_DIR/output.txt $WORKSPACE/output.tsv
    fi

    gen3_log_info "The manifest is saved to $WORKSPACE/output.tsv"

    rm $XDG_RUNTIME_DIR/manifest.json
  fi
}

command="$1"
shift
case "$command" in
  'create')
    gen3_manifest_generating "$@"
    ;;
  'status')
    gen3_manifest_generating_status "$@"
    ;;
  'cleanup')
    gen3_manifest_generating_cleanup
    ;;
  'get-manifest')
    gen3_get_output_manifest "$@"
    ;;
  'help')
    gen3_bucket_manifest_help "$@"
    ;;
  *)
    gen3_bucket_manifest_help
    ;;
esac
exit $?