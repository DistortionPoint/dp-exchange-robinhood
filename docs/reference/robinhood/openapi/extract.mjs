import { readFileSync, writeFileSync } from "node:fs";
const [src, out] = process.argv.slice(2);
const js = readFileSync(src, "utf8");
const start = js.indexOf("JSON.parse('");
if (start < 0) throw new Error("no JSON.parse literal");
let i = start + "JSON.parse('".length, lit = "";
for (; i < js.length; i++) {
  const c = js[i];
  if (c === "\\") { lit += c + js[i + 1]; i++; continue; }
  if (c === "'") break;
  lit += c;
}
const text = Function(`return '${lit}'`)();
const spec = JSON.parse(text);
writeFileSync(out, JSON.stringify(spec, null, 2) + "\n");
console.log(spec.openapi, spec.info?.title, Object.keys(spec.paths || {}).length, "paths");
