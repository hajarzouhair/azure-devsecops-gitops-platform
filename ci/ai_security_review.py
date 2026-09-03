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
project_endpoint = os.environ["FOUNDRY_PROJECT_ENDPOINT"].rstrip("/")
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

# NOTE: api-version ajouté — probablement la cause du 400, à confirmer/
# ajuster contre le panneau "View code" de l'agent dans le portail Foundry
# si l'erreur persiste malgré ce correctif.
API_VERSION = "v1"

endpoint = (
    f"{project_endpoint}"
    f"/agents/{agent_name}"
    f"/endpoint/protocols/openai/responses"
    f"?api-version={API_VERSION}"
)

response = requests.post(
    endpoint,
    headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    },
    json={
        "input": prompt,
    },
    timeout=300,
)

# Affiche toujours le détail avant de potentiellement lever une exception —
# indispensable pour diagnostiquer un futur échec sans devoir ajouter ce
# print après coup à chaque fois.
print("STATUS:", response.status_code)
if response.status_code >= 400:
    print("BODY:", response.text)

response.raise_for_status()

data = response.json()

if "output_text" in data:
    report = data["output_text"]
elif "output" in data:
    # Structure alternative possible de la Responses API : une liste de
    # blocs de contenu plutôt qu'un texte déjà assemblé.
    report = json.dumps(data["output"], indent=2, ensure_ascii=False)
else:
    report = json.dumps(data, indent=2, ensure_ascii=False)

with open("ai-security-report.md", "w", encoding="utf-8") as f:
    f.write("# AI Security Review\n\n")
    f.write(report)

print("Rapport généré avec succès.")
