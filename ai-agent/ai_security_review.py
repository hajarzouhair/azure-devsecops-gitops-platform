import json
import os
import time
import requests

def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

def summarize_trivy(trivy_data, max_vulns=30):
    findings = []
    for result in trivy_data.get("Results", []):
        target = result.get("Target", "")
        for vuln in result.get("Vulnerabilities", []) or []:
            severity = vuln.get("Severity", "")
            if severity in ("HIGH", "CRITICAL"):
                findings.append({
                    "target": target,
                    "id": vuln.get("VulnerabilityID"),
                    "severity": severity,
                    "pkg": vuln.get("PkgName"),
                    "installed": vuln.get("InstalledVersion"),
                    "fixed": vuln.get("FixedVersion"),
                    "title": vuln.get("Title"),
                })
    findings.sort(key=lambda v: v["severity"] != "CRITICAL")
    truncated = len(findings) > max_vulns
    return findings[:max_vulns], truncated

def summarize_sast(sast_data, max_findings=20):
    findings = []
    for vuln in sast_data.get("vulnerabilities", []) or []:
        findings.append({
            "id": vuln.get("id"),
            "severity": vuln.get("severity"),
            "name": vuln.get("name"),
            "file": (vuln.get("location") or {}).get("file"),
            "line": (vuln.get("location") or {}).get("start_line"),
        })
    truncated = len(findings) > max_findings
    return findings[:max_findings], truncated

def summarize_sbom(sbom_data, max_packages=50):
    packages = sbom_data.get("packages", [])
    summary = [
        {"name": p.get("name"), "version": p.get("versionInfo")}
        for p in packages[:max_packages]
    ]
    return summary, len(packages) > max_packages

def push_metrics(duration, status_label):
    pushgateway_url = os.environ.get("PUSHGATEWAY_URL")
    pushgateway_auth = os.environ.get("PUSHGATEWAY_AUTH")
    if not pushgateway_url or not pushgateway_auth:
        print("AVERTISSEMENT: PUSHGATEWAY_URL ou PUSHGATEWAY_AUTH absent — métriques non envoyées.")
        return
    user, pwd = pushgateway_auth.split(":", 1)
    metrics = (
        f'# TYPE ai_agent_call_duration_seconds gauge\n'
        f'ai_agent_call_duration_seconds {duration:.2f}\n'
        f'# TYPE ai_agent_call_total counter\n'
        f'ai_agent_call_total{{status="{status_label}"}} 1\n'
    )
    try:
        resp = requests.post(
            f"{pushgateway_url}/metrics/job/ai_security_review",
            data=metrics,
            auth=(user, pwd),
            timeout=10,
        )
        print(f"PUSH METRICS STATUS: {resp.status_code}")
        if resp.status_code >= 300:
            print(f"PUSH METRICS BODY: {resp.text}")
    except requests.RequestException as e:
        print(f"Avertissement : échec de l'envoi des métriques ({e})")


start_time = time.time()

try:
    trivy_raw = load_json("trivy-report.json")
    sast_raw = load_json("gl-sast-report.json")
    sbom_raw = load_json("sbom.json")

    trivy_summary, trivy_truncated = summarize_trivy(trivy_raw)
    sast_summary, sast_truncated = summarize_sast(sast_raw)
    sbom_summary, sbom_truncated = summarize_sbom(sbom_raw)

    gitlab_oidc_token = os.environ["AZURE_AI_REVIEW_TOKEN"]
    client_id = os.environ["AI_REVIEW_CLIENT_ID"]
    tenant_id = os.environ["AZURE_TENANT_ID"]
    project_endpoint = os.environ["FOUNDRY_PROJECT_ENDPOINT"].rstrip("/")
    agent_name = os.environ["FOUNDRY_AGENT_NAME"]

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

    prompt = f"""
Tu es un expert DevSecOps.
Analyse les résultats du pipeline CI/CD ci-dessous. Les listes sont
déjà filtrées sur les sévérités HIGH/CRITICAL et limitées en nombre
d'entrées pour tenir dans le contexte — mentionne-le si pertinent.

## TRIVY (vulnérabilités HIGH/CRITICAL{", tronqué" if trivy_truncated else ""})
{json.dumps(trivy_summary, indent=2)}

## SAST{", tronqué" if sast_truncated else ""}
{json.dumps(sast_summary, indent=2)}

## SBOM (extrait des packages{", tronqué" if sbom_truncated else ""})
{json.dumps(sbom_summary, indent=2)}

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
        f"{project_endpoint}/agents/{agent_name}"
        f"/endpoint/protocols/openai/responses?api-version=v1"
    )

    response = requests.post(
        endpoint,
        headers={"Authorization": f"Bearer {access_token}", "Content-Type": "application/json"},
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

    duration = time.time() - start_time
    push_metrics(duration, "success")
    print(f"Rapport généré avec succès (durée: {duration:.1f}s).")

except Exception:
    duration = time.time() - start_time
    push_metrics(duration, "failure")
    raise
