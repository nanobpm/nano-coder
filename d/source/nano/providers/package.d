/// Provider construction.
module nano.providers;

public import nano.providers.openai;
public import nano.providers.anthropic;
public import nano.providers.mock;
import nano.config;
import nano.llm;

LLMClient makeClient(ResolvedProvider p)
{
    final switch (p.config.kind)
    {
        case ProviderKind.openai: return new OpenAIClient(p);
        case ProviderKind.anthropic: return new AnthropicClient(p);
        case ProviderKind.githubCopilot: return new CopilotClient(p);
    }
}
