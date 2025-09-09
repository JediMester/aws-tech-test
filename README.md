# AWS Tech test - EC2 + ECS Fargate + ALB + Lambda/API Gateway (CloudFormation)

## Overview

This project deploys a small, modular AWS architecture using CloudFormation:
- EC2 (Amazon Linux 2) – running NGINX (HTTP/80), optional SSH
- ECS Fargate – containerized web app, behind ALB, public access
- Lambda + API Gateway – endpoint that:
	- queries the public IP of the running EC2 instance (DescribeInstances)
	- performs an HTTP health check on it
	- returns a JSON response

The templates are parameterized, so they can be easily switched to another region/image/port.

Directory tree:

```sh
.
├─ cloudformation/
│  ├─ ec2-stack.yml        # EC2 + SG + (optional SSH) + Outputs (PublicIP/DNS)
│  ├─ ecs-stack.yml        # VPC + 2 public subnet (different/separate AZs) + ALB + Fargate service
│  └─ lambda-stack.yml     # Lambda + IAM role + API Gateway (REGIONAL)
├─ lambda/
│  └─ get-ec2-status.py    # (reference) same logic inline in the CFN as well
└─ ecs-app/                # (optional) source/Dockerfile of custom app if needed
```

### Architecture (ASCII)

```sh
[Internet]
    |
    |           +------------------------+
    +---------> |  API Gateway (/status) | ---> [Lambda] --(DescribeInstances)--> [EC2 NGINX]
    |           +------------------------+                                 \--HTTP GET--> http://<EC2_IP>/
    |
    |           +----------------------+
    +---------> |  ALB (HTTP :80)     | --> [Target Group (ip)] --> [ECS Fargate Task(s)]
                +----------------------+
                         |
                      VPC (2x public subnet, külön AZ)
```

### Prerequisites

- AWS CLI v2, configured profile (--profile) and region (--region)
- Own Docker Hub image for the container (optional)
- EC2 KeyPair for SSH (optional)

Recommended shell variables:

```sh
export AWS_PROFILE=default
export AWS_REGION=eu-west-1
```

## 1. EC2 stack (Nginx + optional SSH)

Key features:
- AL2 AMI from SSM's “latest” parameter (no hardcode)
- Port 80/tcp open to the world
- Optional SSH (22/tcp) – only opens if you provide a KeyName
- Output: InstanceId, PublicIP, PublicDNS

### Deploy without SSH:
```sh
aws cloudformation deploy \
  --stack-name ec2-web-stack \
  --template-file cloudformation/ec2-stack.yml \
  --region $AWS_REGION --profile $AWS_PROFILE
```

### Deploy with SSH (recommended /32):
1. KeyPair creation in AWS (private key locally)
```sh
aws ec2 create-key-pair \
  --key-name aws_def_key \
  --query 'KeyMaterial' --output text \
  --region $AWS_REGION --profile $AWS_PROFILE > ~/.ssh/aws_def_key.pem
chmod 400 ~/.ssh/aws_def_key.pem
```

2. Get own public IP
```sh
MYIP=$(curl -s https://checkip.amazonaws.com)
```
3. Deploy
```sh
aws cloudformation deploy \
  --stack-name ec2-web-stack \
  --template-file cloudformation/ec2-stack.yml \
  --parameter-overrides KeyName=aws_def_key SSHCidr=${MYIP}/32 \
  --region $AWS_REGION --profile $AWS_PROFILE
```
### Outputs and quick check:
```sh
aws cloudformation describe-stacks \
  --stack-name ec2-web-stack \
  --query "Stacks[0].Outputs" \
  --region $AWS_REGION --profile $AWS_PROFILE

EC2_IP=$(aws cloudformation describe-stacks \
  --stack-name ec2-web-stack \
  --query "Stacks[0].Outputs[?OutputKey=='PublicIP'].OutputValue" \
  --output text --region $AWS_REGION --profile $AWS_PROFILE)

curl "http://$EC2_IP/"
# SSH (if there is KeyName):
ssh -i ~/.ssh/aws_def_key.pem ec2-user@$EC2_IP
```
## 2. Lambda + API Gateway stack

### What it does:

API: GET /status -> Lambda -> EC2 DescribeInstances (based on tag: Name=CF-EC2-Web) -> HTTP GET to EC2 IP -> JSON

### Deployment:
```sh
aws cloudformation deploy \
  --stack-name lambda-stack \
  --template-file cloudformation/lambda-stack.yml \
  --capabilities CAPABILITY_NAMED_IAM \
  --region $AWS_REGION --profile $AWS_PROFILE
```

### API URL:
```sh
aws cloudformation describe-stacks \
  --stack-name lambda-stack \
  --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue" \
  --output text --region $AWS_REGION --profile $AWS_PROFILE
```

# Testing:
```sh
curl "https://<api-id>.execute-api.${AWS_REGION}.amazonaws.com/prod/status"
# Expected output: {"ec2_ip":"<ip>","health":{"http_status":200,"ok":true}}
```
NOTE: the Lambda code uses the standard urllib.request lib, so there is no external dependency.


## 3. ECS Fargate + ALB stack

### What it does:
- VPC + 2 public subnets in separate AZs
- Internet-facing ALB (80/tcp)
- Fargate service with awsvpc network, AssignPublicIp=ENABLED
- TargetGroup IP type, HealthCheck path parameterizable

### Deploy (for testing, guaranteed success):
```sh
aws cloudformation deploy \
  --stack-name ecs-stack \
  --template-file cloudformation/ecs-stack.yml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      ContainerImage=nginxdemos/hello:latest \
      ContainerPort=80 \
      HealthCheckPath=/ \
  --region $AWS_REGION --profile $AWS_PROFILE
```

### ALB DNS + test:
```sh
ALB=$(aws cloudformation describe-stacks \
  --stack-name ecs-stack \
  --query "Stacks[0].Outputs[?OutputKey=='ALBDNSName'].OutputValue" \
  --output text --region $AWS_REGION --profile $AWS_PROFILE)

curl -i "http://$ALB/"
```

### Own DockerHub image (public repo) - a node.js app listening on port 8080/tcp: mcudivide/sample-nodejs-app:latest
### Original source code and github repo: https://github.com/digitalocean/sample-nodejs
```sh
aws cloudformation deploy \
  --stack-name ecs-stack \
  --template-file cloudformation/ecs-stack.yml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      ContainerImage=mcudivide/sample-nodejs-app:latest \
      ContainerPort=8080 \
      HealthCheckPath=/ \
  --region $AWS_REGION --profile $AWS_PROFILE
```

### Quick debugging

### CloudFormation events - why it might have failed:
```sh
aws cloudformation describe-stack-events \
  --stack-name <STACK_NAME> \
  --query "StackEvents[?contains(ResourceStatus,'FAILED')].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]" \
  --output table --region $AWS_REGION --profile $AWS_PROFILE
```

### Lambda logs (more robust):
```sh
FN=$(aws cloudformation describe-stack-resources \
  --stack-name lambda-stack \
  --logical-resource-id EC2StatusFunction \
  --query "StackResources[0].PhysicalResourceId" \
  --output text --region $AWS_REGION --profile $AWS_PROFILE)

aws logs tail "/aws/lambda/$FN" --since 10m \
  --region $AWS_REGION --profile $AWS_PROFILE
```

### ECS service events:
```sh
aws ecs describe-services \
  --cluster techtest-cluster \
  --services techtest-service \
  --query "services[0].events[0:10].message" \
  --region $AWS_REGION --profile $AWS_PROFILE
```

### TargetGroup health:
```sh
TG_ARN=$(aws cloudformation describe-stack-resources \
  --stack-name ecs-stack \
  --query "StackResources[?LogicalResourceId=='TargetGroup'].PhysicalResourceId" \
  --output text --region $AWS_REGION --profile $AWS_PROFILE)

aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --region $AWS_REGION --profile $AWS_PROFILE
```

### Common pitfalls might be:
- Region mismatch (EC2 in a different region than Lambda/ECS/ALB)
- Port mismatch (app 8080 <-> TargetGroup/ALB 80)
- HealthCheckPath returns 404
- Docker Hub rate limit -> ECR recommended


## Cleanup (cost reduction)

### Deleting stacks in the following order (because of dependencies):
```sh
aws cloudformation delete-stack --stack-name ecs-stack --region $AWS_REGION --profile $AWS_PROFILE
aws cloudformation delete-stack --stack-name lambda-stack --region $AWS_REGION --profile $AWS_PROFILE
aws cloudformation delete-stack --stack-name ec2-web-stack --region $AWS_REGION --profile $AWS_PROFILE

aws cloudformation wait stack-delete-complete --stack-name ecs-stack --region $AWS_REGION --profile $AWS_PROFILE
aws cloudformation wait stack-delete-complete --stack-name lambda-stack --region $AWS_REGION --profile $AWS_PROFILE
aws cloudformation wait stack-delete-complete --stack-name ec2-web-stack --region $AWS_REGION --profile $AWS_PROFILE
```

## Makefile - Customizable and configurable, a One-Shot nested deploy (S3 create + sync + deploy --> optional - included in the main/root dir.)
```sh
# create secured S3 bucket, sync templates, deploy nested stacks
make deploy-all

# show key outputs (EC2 Public IP/DNS, API URL, ALB DNS)
make outputs-main
```
The Makefile will:
- create S3 bucket `techtest-cfn-templates-<account>-<region>`
- block public access, enable SSE-S3
- sync `cloudformation/` -> `s3://<bucket>/cloudformation/`
- deploy `cloudformation/main.yml` with parameters,
- print useful outputs.

### Deploy individual stacks (standalone)

Note: You can still deploy stacks separately (see commands inside the README sections if needed).

### Switch container image quickly
```sh
# Switch to hello nginx on port 80
make set-image-hello

# Switch to Node app on port 8080 (public Docker Hub image)
make set-image-node
```
### Cleanup (cost control)
```sh
# delete nested stacks, then (optionally) empty & delete the S3 bucket
make nuke
```

## Design Rationale

### CloudFormation & modularity:
- Modular templates (ec2-stack.yml, lambda-stack.yml, ecs-stack.yml) -> clear responsibilities:
    - easy to develop/debug separately
- Root main.yml (nested stack) -> full deployment with a single command:
    - reusable in any region with S3 TemplateURL
### EC2 (simple web + health target)
- AL2 AMI from SSM -> no region-dependent AMI hardcode, always up to date
- UserData NGINX -> deterministic, fast “hello web” target for Lambda health check.
- Optional SSH KeyName + SSHCidr -> no ssh by default, can be narrowed to /32 if needed:
    - infrastructure security baseline
### Lambda + API Gateway
- REGIONAL API -> lower latency in the target region, simpler (no edge deploy)
- Standard lib (urllib) -> no external dependency/layer:
    - fewer points of failure
    - faster cold start
- Tag-based EC2 filtering (Name=CF-EC2-Web) -> finds our machine deterministically even with multiple instances
- Environmental variables -> region/timeout configurable from CFN parameters
### ECS Fargate + ALB
- Fargate -> no EC2 capacity/patching issues:
    - pay-per-task
    - clean serverless ops
- VPC + 2 public subnets in separate AZs -> higher availability for ALB and tasks
- ALB + TargetGroup (ip) -> mandatory for Fargate:
    - Layer7 health check
    - path/HTTP code-based check
- AssignPublicIp=ENABLED -> access to Docker Hub/ECR without NAT (simple test environment)
- Alternative for production: private subnets + NAT Gateway (more expensive, but more secure)
- Parameterized ContainerImage, ContainerPort, HealthCheckPath -> you can run any public image (e.g., Node.js app on 8080)
- CloudWatch Logs (/ecs/<env>-app) -> out-of-the-box task logs
### Security & costs
- S3 public access block + SSE-S3 -> templates are private and encrypted
- IAM managed policies -> quick start
    - in prod, it is worth narrowing down to least privilege (custom policy)
- HTTP/80 for demonstration only -> prod: ACM cert + HTTPS listener + (optional) AWS WAF
- Cost reduction:
    - “DesiredCount=1”
    - low CPU/Mem (256/512)
    - short log retention (7 days)
    - stack delete at the end


## Security notes
- Only enable SSH - and only for /32 - if necessary.
- ALB HTTP/80 public - TLS (ACM cert + HTTPS listener) recommended in production.
- IAM roles have managed policies - they can be refined to minimum permissions.
