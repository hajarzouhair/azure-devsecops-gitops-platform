import json
import os
import requests

def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

trivy = load_json("trivy-report.json")
sast = load_json("gl-sast-report.json")
sbom = load_json("sbom.json")

gitlab_oidc_token = os.environ["AZURE_AI_REVIEW_TOKEN"]
client_id = os.environ["AI_REVIEW_CLIENT_ID"]
tenant_id = os.environ["AZURE_TENANT_ID"]
project_endpoint = os.environ["FOUNDRY_PROJECT_ENDPOINT"].rstrip("/")
agent_name = os.environ["FOUNDRY_AGENT_NAME"]

# --------------------------------------------------------------------
# Étape 1 : échanger le jeton OIDC GitLab contre un vrai jeton d'accès
# Azure AD, via le flux "client credentials" avec assertion fédérée.
# C'est l'équivalent Python de "az login --federated-token" utilisé
# dans les autres jobs du pipeline.
# --------------------------------------------------------------------
token_url = f"https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token"
token_resp = requests.post(token_url, data={
    "client_id": client_id,
    "scope": "https://ai.azure.com/.default",
    "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
    "client_assertion": gitlab_oidc_token,
    "grant_type": "client_credentials",
})
print("TOKEN EXCHANGE STATUS:", token_resp.status_code)
if token_resp.status_code >= 400:
    print("TOKEN EXCHANGE BODY:", token_resp.text)
token_resp.raise_for_status()

access_token = token_resp.json()["access_token"]

# --------------------------------------------------------------------
# Étape 2 : appeler l'agent Foundry avec le vrai jeton d'accès
# --------------------------------------------------------------------
prompt = f"""
Tu es un expert DevSecOps.
Analyse les résultats du pipeline CI/CD.

## TRIVY
{json.dumps(trivy, indent=2)}

## SAST
{json.dumps(sast, indent=2)}

## SBOM
{json.dumps(sbom, indent=2)}

Fournis une analyse structurée contenant :
1. Résumé exécutif
2. Vulnérabilités CRITICAL
3. Vulnérabilités HIGH
4. Findings SAST
5. Analyse du SBOM
6. Corrélation des findings
7. Risques principaux
8. Actions de remédiation
9. Recommandation de déploiement

Analyse uniquement les données fournies.
N'effectue aucune modification sur l'infrastructure.
"""

endpoint = (
    f"{project_endpoint}"
    f"/agents/{agent_name}"
    f"/endpoint/protocols/openai/responses"
    f"?api-version=v1"
)

response = requests.post(
    endpoint,
    headers={
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
    },
    json={"input": prompt},
    timeout=300,
)

print("STATUS:", response.status_code)
if response.status_code >= 400:
    print("BODY:", response.text)
response.raise_for_status()

data = response.json()

if "output_text" in data:
    report = data["output_text"]
elif "output" in data:
    report = json.dumps(data["output"], indent=2, ensure_ascii=False)
else:
    report = json.dumps(data, indent=2, ensure_ascii=False)

with open("ai-security-report.md", "w", encoding="utf-8") as f:
    f.write("# AI Security Review\n\n")
    f.write(report)

print("Rapport généré avec succès.")
