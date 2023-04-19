# import os
# import requests

# pr_number = os.environ['PR_NUMBER']
# url = f'https://api.github.com/repos/{os.environ["GITHUB_REPOSITORY"]}/actions/runs?event=push&status=success&branch={os.environ["GITHUB_HEAD_REF"]}&per_page=100'
# headers = {
#   'Accept': 'application/vnd.github+json',
#   'Authorization': f'token {os.environ["GITHUB_TOKEN"]}',
# }

# response = requests.get(url, headers=headers)
# response.raise_for_status()

# for run in response.json()['workflow_runs']:
#   if run['head_branch'] == os.environ['GITHUB_HEAD_REF'] and run['pull_requests'][0]['number'] == int(pr_number):
#     artifacts_url = f'{run["url"]}/artifacts'
#     artifacts_response = requests.get(artifacts_url, headers=headers)
#     artifacts_response.raise_for_status()
#     for artifact in artifacts_response.json()['artifacts']:
#       artifact_url = f'{artifacts_url}/{artifact["id"]}/zip'
#       artifact_response = requests.get(artifact_url, headers=headers)
#       artifact_response.raise_for_status()
#       with open('artifact.txt', 'w+') as f:
#         f.write(artifact_response.content)

# #       with open('artifact.txt', 'wb') as f:
# #         f.write(artifact_response.content)


import os
import requests
import json

# Set up API requests headers
headers = {
  "Accept": "application/vnd.github.v3+json",
  "Authorization": f"Bearer {os.environ['GITHUB_TOKEN']}"
}

# Get all pull requests for the repository
repo_url = os.environ["GITHUB_REPOSITORY"]
pulls_url = f"https://api.github.com/repos/{repo_url}/pulls"
response = requests.get(pulls_url, headers=headers)
response.raise_for_status()

# Filter the pull requests to find unmerged ones
pull_requests = json.loads(response.content)
unmerged_pulls = [pull for pull in pull_requests if not pull["merged"] and pull["state"] == "open"]

# Print the list of unmerged pull requests
for pull in unmerged_pulls:
    print(f"PR #{pull['number']}: {pull['title']}")
