import { dump as yamlDump, load as yamlLoad } from "js-yaml";
import { validateConfig } from "../src/config/validate.js";

const KEY_ORDER = [
  "version",
  "budgets",
  "name",
  "description",
  "scope",
  "users",
  "cost_center",
  "team",
  "organization",
  "metered_credits_only",
  "amount",
  "enforce",
  "alerts",
  "allow_shared_cost_center",
];

export function parseConfigYaml(raw, source = "YAML file") {
  let doc;
  try {
    doc = yamlLoad(raw);
  } catch (cause) {
    if (cause && typeof cause.message === "string" && cause.message.includes("input is empty")) return {};
    throw new Error(`Could not parse ${source}: ${cause.message}`, { cause });
  }

  if (doc === undefined || doc === null) return {};
  if (typeof doc !== "object" || Array.isArray(doc)) {
    const got = Array.isArray(doc) ? "a list" : typeof doc;
    throw new Error(`${source} must be a YAML mapping at the top level (got ${got}).`);
  }
  return doc;
}

export function validateStudioConfig(doc) {
  return validateConfig(doc);
}

export function serializeConfigYaml(doc) {
  return yamlDump(doc, {
    lineWidth: -1,
    noRefs: true,
    sortKeys: (left, right) => {
      const leftIndex = KEY_ORDER.indexOf(left);
      const rightIndex = KEY_ORDER.indexOf(right);
      if (leftIndex === -1 && rightIndex === -1) return left.localeCompare(right);
      if (leftIndex === -1) return 1;
      if (rightIndex === -1) return -1;
      return leftIndex - rightIndex;
    },
  });
}