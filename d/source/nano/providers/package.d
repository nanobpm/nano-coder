/// Provider construction.
module nano.providers;

public import nano.providers.openai;
public import nano.providers.anthropic;
public import nano.providers.mock;
public import nano.providers.demo;
public import nano.providers.muse;
import nano.config;
import nano.llm;

LLMClient makeClient(ResolvedProvider p)
{
    final switch (p.config.kind)
    {
        case ProviderKind.openai: return new OpenAIClient(p);
        case ProviderKind.anthropic: return new AnthropicClient(p);
        case ProviderKind.githubCopilot: return new CopilotClient(p);
        case ProviderKind.muse: return new MuseClient(p);
        case ProviderKind.mock: return new DemoClient(p.name, p.model);
    }
}
