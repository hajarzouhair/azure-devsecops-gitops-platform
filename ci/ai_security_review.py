import json
import os
import requests


def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


trivy = load_json("trivy-report.json")
sast = load_json("gl-sast-report.json")
sbom = load_json("sbom.json")

token = os.environ["AZURE_AI_REVIEW_TOKEN"]

project_endpoint = os.environ["FOUNDRY_PROJECT_ENDPOINT"]
agent_name = os.environ["FOUNDRY_AGENT_NAME"]

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
)

response = requests.post(
    endpoint,
    headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    },
    json={
        "input": prompt
    },
    timeout=300
)

response.raise_for_status()

data = response.json()

if "output_text" in data:
    report = data["output_text"]
else:
    report = json.dumps(data, indent=2)

with open("ai-security-report.md", "w", encoding="utf-8") as f:
    f.write("# AI Security Review\n\n")
    f.write(report)
