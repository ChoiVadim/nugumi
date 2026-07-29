import { createScriptedFauxProvider } from "./faux-provider.js";
import { buildDefinition, runSidecar } from "./session.js";

await runSidecar(
  buildDefinition((runtime) => {
    const faux = createScriptedFauxProvider(() => runtime.chargeTurn());
    return { provider: faux.provider, model: faux.getModel() };
  }),
);
