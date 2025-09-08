import boto3
#import requests
import urllib.requests
import json
import os

REGION = os.environ.get("REGION", "eu-west-1")
TAG_KEY = os.environ.get("TAG_KEY", "Name")
TAG_VALUE = os.environ.get("TAG_VALUE", "CF-EC2-Web")
TIMEOUT_SECONDS = int(os.environ.get("TIMEOUT_SECONDS", "2"))

def http_get(url, timeout):
              req = urllib.request.Request(url, method="GET")
              with urllib.request.urlopen(req, timeout=timeout) as resp:
                  return resp.getcode()

def lambda_handler(event, context):
    ec2 = boto3.client('ec2', region_name=REGION)

    try:
        resp = ec2.describe_instances(
            Filters=[
		{'Name': 'instance-state-name', 'Values': ['running']},
		{"Name": f"tag:{TAG_KEY}", "Values": [TAG_VALUE]},
	    ]
        )
	
	reservations = resp.get("Reservations", [])
        if not reservations or not reservations[0].get("Instances"):
            return {
                "statusCode": 404,
                "body": json.dumps({"error": "No matching running instance found"})
            }

        instance = reservations[0]['Instances'][0]
        public_ip = instance.get("PublicIpAddress")
	if not public_ip:
            return {
                "statusCode": 503,
                "body": json.dumps({"error": "Instance has no public IP"})
            }

        try:
            #r = requests.get(f'http://{public_ip}', timeout=TIMEOUT_SECONDS)
            status = http_get(f"http://{public_ip}", TIMEOUT_SECONDS)
	    health = {"http_status": status, "ok": 200 <= status < 400}
        except Exception as e:
            #status = str(e)
	    health = {"error": str(e), "ok": False}

        return {
            "statusCode": 200,
            "body": json.dumps({
                "ec2_ip": public_ip,
                "health": health
            })
        }

    except Exception as e:
        #return {
        #    'statusCode': 500,
        #    'body': json.dumps({'error': str(e)})
        #}
	return {"statusCode": 500, "body": json.dumps({"error": str(e)})}

