// Strip the `reasoning` and `thinking` fields from outgoing requests.
// CCR's openai transformer translates Anthropic `thinking` -> OpenAI
// Responses-API `reasoning`, but Azure-OpenAI Chat Completions endpoints
// reject `reasoning` as an unknown parameter. Run this transformer AFTER
// `openai` in the chain.

class StripReasoning {
  name = "strip-reasoning";

  async transformRequestIn(request) {
    if (request && typeof request === "object") {
      delete request.reasoning;
      delete request.reasoning_effort;
      delete request.thinking;
    }
    return request;
  }
}

module.exports = StripReasoning;
