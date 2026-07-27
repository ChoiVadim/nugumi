import { createScriptedFauxProvider } from "./faux-provider.js";
import { runSidecar } from "./session.js";

await runSidecar((runtime) => {
  const faux = createScriptedFauxProvider(() => runtime.chargeTurn());
  return { provider: faux.provider, model: faux.getModel() };
});
