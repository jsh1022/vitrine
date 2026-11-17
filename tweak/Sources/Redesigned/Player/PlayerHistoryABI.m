// The stored native factories return a concrete Swift class in x0. Casting them
// to () -> AnyObject is invalid: that existential result is returned indirectly.
// Keep the original closure's swiftself context and ownership convention.
typedef void *__attribute__((swiftcall)) (*SGRQueueFactory)(void *__attribute__((swift_context)));
void *SGRQueueFactoryCall(void *code, void *context) {
    return ((SGRQueueFactory)code)(context);
}

// ConfigurableComponent<Model,...>._update takes its generic Optional<Model>
// and Optional<(PartialKeyPath<Model>, Any)> indirectly. Swift constructs and
// destroys both with the actual native types before/after this call.
typedef void __attribute__((swiftcall)) (*SGRQueueUpdate)(const void *, const void *, void *__attribute__((swift_context)));
void SGRQueueUpdateCall(void *code, void *context, const void *model, const void *delta) {
    ((SGRQueueUpdate)code)(model, delta, context);
}
