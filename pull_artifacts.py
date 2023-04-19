import os
import requests

pr_number = os.environ['PR_NUMBER']
url = f'https://api.github.com/repos/{os.environ["GITHUB_REPOSITORY"]}/actions/runs?event=push&status=success&branch={os.environ["GITHUB_HEAD_REF"]}&per_page=100'
headers = {
  'Accept': 'application/vnd.github+json',
  'Authorization': f'token {os.environ["GITHUB_TOKEN"]}',
}

response = requests.get(url, headers=headers)
response.raise_for_status()

for run in response.json()['workflow_runs']:
  if run['head_branch'] == os.environ['GITHUB_HEAD_REF'] and run['pull_requests'][0]['number'] == int(pr_number):
    artifacts_url = f'{run["url"]}/artifacts'
    artifacts_response = requests.get(artifacts_url, headers=headers)
    artifacts_response.raise_for_status()
    for artifact in artifacts_response.json()['artifacts']:
      artifact_url = f'{artifacts_url}/{artifact["id"]}/zip'
      artifact_response = requests.get(artifact_url, headers=headers)
      artifact_response.raise_for_status()
      with open('artifact.txt', 'w+') as f:
        f.write(artifact_response.content)

#       with open('artifact.txt', 'wb') as f:
#         f.write(artifact_response.content)
