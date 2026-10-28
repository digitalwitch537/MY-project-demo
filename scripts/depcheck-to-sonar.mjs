import fs from "node:fs";
import path from "node:path";

const reportPath = process.argv[2] || "reports/dependency-check-report.json";
const outputPath = process.argv[3] || "reports/sonar-external-issues.json";
const dastFile = process.argv[4] || "dast/dependency-findings.js";
const normalizedDastFile = dastFile.replace(/^\.\//, "");

function severityFromScore(score, fallback) {
	if (Number.isFinite(score)) {
		if (score >= 9) return "BLOCKER";
		if (score >= 7) return "CRITICAL";
		if (score >= 4) return "MAJOR";
		if (score > 0) return "MINOR";
		return "INFO";
	}
	const value = String(fallback || "").toUpperCase();
	if (value === "CRITICAL") return "BLOCKER";
	if (value === "HIGH") return "CRITICAL";
	if (value === "MEDIUM" || value === "MODERATE") return "MAJOR";
	if (value === "LOW") return "MINOR";
	return "INFO";
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

function packageName(dependency) {
	const packageIds = Array.isArray(dependency.packages) ? dependency.packages : [];
	for (const entry of packageIds) {
		if (entry && typeof entry.id === "string") {
			return entry.id.replace(/^pkg:[^/]+\//, "").split("@")[0] || entry.id;
		}
	}
	return dependency.fileName || dependency.filePath || "unknown-package";
}

function clean(value, max = 500) {
	return String(value || "")
		.replace(/\s+/g, " ")
		.trim()
		.slice(0, max);
}

const rulesById = new Map();
const issues = [];

if (!fs.existsSync(reportPath)) {
	console.warn(`Dependency-Check report not found at ${reportPath}; writing an empty Sonar report`);
} else {
	const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
	const dependencies = Array.isArray(report.dependencies) ? report.dependencies : [];
	const seen = new Set();

	for (const dependency of dependencies) {
		const vulnerabilities = Array.isArray(dependency.vulnerabilities) ? dependency.vulnerabilities : [];
		for (const vulnerability of vulnerabilities) {
			const name = vulnerability.name || "unknown-vulnerability";
			const pkg = packageName(dependency);
			const source = dependency.filePath || dependency.fileName || "unknown-source";
			const score = vulnerability.cvssv3?.baseScore ?? vulnerability.cvssv2?.score;
			const key = `${name}|${pkg}|${source}`;
			if (seen.has(key)) continue;
			seen.add(key);

			const severity = severityFromScore(score, vulnerability.severity);
			if (!rulesById.has(name)) {
				rulesById.set(name, {
					id: name,
					name,
					description: "Vulnerable dependency reported by OWASP Dependency-Check.",
					engineId: "OWASP Dependency-Check",
					cleanCodeAttribute: "TRUSTWORTHY",
					type: "VULNERABILITY",
					severity,
					impacts: [{ softwareQuality: "SECURITY", severity: mqrSeverity(severity) }],
				});
			}

			const version = clean(dependency.version || dependency.fileName, 120);
			const description = clean(vulnerability.description, 500);
			issues.push({
				ruleId: name,
				effortMinutes: 0,
				primaryLocation: {
					message: `${name} in ${pkg}${version ? ` (${version})` : ""}${Number.isFinite(score) ? `, CVSS ${score}` : ""}. ${description}`,
					filePath: normalizedDastFile,
					textRange: { startLine: 1, endLine: 1 },
				},
			});
		}
	}
}

issues.forEach((issue, index) => {
	issue.primaryLocation.textRange = { startLine: index + 2, endLine: index + 2 };
});

const rules = [...rulesById.values()];
const lines = issues.map((issue) => JSON.stringify(`${issue.ruleId} | ${issue.primaryLocation.message}`));
fs.mkdirSync(path.dirname(dastFile), { recursive: true });
fs.writeFileSync(dastFile, `export const dependencyFindings = [\n${lines.map((line) => `\t${line},`).join("\n")}\n];\n`);

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, `${JSON.stringify({ rules, issues }, null, 2)}\n`);

const counts = issues.reduce((accumulator, issue) => {
	const rule = rulesById.get(issue.ruleId);
	accumulator[rule.severity] = (accumulator[rule.severity] || 0) + 1;
	return accumulator;
}, {});

console.log(`Dependency-Check findings converted: ${issues.length}`);
console.log(`Severity counts: ${JSON.stringify(counts)}`);
console.log(`Wrote ${dastFile} (${issues.length} lines)`);
console.log(`Wrote ${outputPath} (${rules.length} rules)`);
