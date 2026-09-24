// Resolve the bundler-style imports in emitted production modules. No DSP copy.
export function resolve(specifier, context, nextResolve) {
  if (specifier.startsWith('./') && !/\.[a-z]+$/.test(specifier)) specifier += '.js'
  return nextResolve(specifier, context)
}
