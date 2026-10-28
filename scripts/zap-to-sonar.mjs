import fs from "node:fs";
import path from "node:path";

const reportPath = process.argv[2] || "reports/zap-report.json";
const outputPath = process.argv[3] || "reports/sonar-external-issues.json";
const dastFile = process.argv[4] || "dast/zap-findings.js";
const normalizedDastFile = dastFile.replace(/^\.\//, "");

function clean(value, max = 500) {
	return String(value || "")
		.replace(/\s+/g, " ")
		.trim()
		.slice(0, max);
}

function severityFromRisk(riskCode) {
	switch (String(riskCode)) {
		case "3":
			return "CRITICAL";
		case "2":
			return "MAJOR";
		case "1":
			return "MINOR";
		default:
			return "INFO";
	}
}

function mqrSeverity(severity) {
	switch (severity) {
		case "BLOCKER":
			return "BLOCKER";
		case "CRITICAL":
			return "HIGH";
		case "MAJOR":
			return "MEDIUM";
		case "MINOR":
			return "LOW";
		default:
			return "INFO";
	}
}

const alertInstances = [];

if (!fs.existsSync(reportPath)) {
	console.warn(`ZAP report not found at ${reportPath}; writing an empty DAST result`);
} else {
	const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
	const sites = Array.isArray(report.site) ? report.site : report.site ? [report.site] : [];

	for (const site of sites) {
		const siteName = site["@name"] || site.name || "unknown-site";
		const alerts = Array.isArray(site.alerts) ? site.alerts : [];
		for (const alert of alerts) {
			const instances = Array.isArray(alert.instances) && alert.instances.length > 0 ? alert.instances : [{ uri: siteName, method: "" }];
			for (const instance of instances) {
				alertInstances.push({
					riskCode: alert.riskcode,
					risk: alert.riskdesc || alert.risk || "Informational",
					pluginId: alert.pluginid || "unknown",
					name: alert.alert || "ZAP finding",
					confidence: alert.confidence || "",
					description: alert.desc || "",
					solution: alert.solution || "",
					uri: instance.uri || siteName,
					method: instance.method || "",
					param: instance.param || "",
					evidence: instance.evidence || "",
				});
			}
		}
	}
}

fs.mkdirSync(path.dirname(dastFile), { recursive: true });
const lines = alertInstances.map((finding) =>
	JSON.stringify(`${finding.risk} | ${finding.pluginId} | ${finding.name} | ${finding.method} ${finding.uri} | param=${finding.param}`)
);
fs.writeFileSync(dastFile, `export const zapFindings = [\n${lines.map((line) => `\t${line},`).join("\n")}\n];\n`);

const existing = fs.existsSync(outputPath) ? JSON.parse(fs.readFileSync(outputPath, "utf8")) : { rules: [], issues: [] };
const existingRules = Array.isArray(existing.rules) ? existing.rules : [];
const existingIssues = Array.isArray(existing.issues) ? existing.issues : [];

const rulesById = new Map(existingRules.map((rule) => [rule.id, rule]));
const zapIssues = alertInstances.map((finding, index) => {
	const ruleId = `zap-${finding.pluginId}`;
	const severity = severityFromRisk(finding.riskCode);
	if (!rulesById.has(ruleId)) {
		rulesById.set(ruleId, {
			id: ruleId,
			name: finding.name,
			description: "Finding reported by OWASP ZAP.",
			engineId: "OWASP ZAP",
			cleanCodeAttribute: "TRUSTWORTHY",
			type: "VULNERABILITY",
			severity,
			impacts: [{ softwareQuality: "SECURITY", severity: mqrSeverity(severity) }],
		});
	}

	return {
		ruleId,
		effortMinutes: 0,
		primaryLocation: {
			message: `${finding.name} (${finding.risk}, confidence: ${finding.confidence || "unknown"}) at ${finding.method} ${finding.uri}${finding.param ? ` parameter ${finding.param}` : ""}. ${clean(finding.description)} Solution: ${clean(finding.solution)}`,
			filePath: normalizedDastFile,
			textRange: { startLine: index + 2, endLine: index + 2 },
		},
	};
});

const merged = {
	rules: [...rulesById.values()],
	issues: [...existingIssues, ...zapIssues],
};

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, `${JSON.stringify(merged, null, 2)}\n`);

console.log(`ZAP findings converted: ${zapIssues.length}`);
console.log(`Wrote ${dastFile} (${alertInstances.length} lines)`);
console.log(`Merged Sonar rules: ${existingRules.length} existing + ${merged.rules.length - existingRules.length} new`);
console.log(`Merged Sonar issues: ${merged.issues.length} -> ${outputPath}`);
