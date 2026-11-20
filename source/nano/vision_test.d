/// Ported vision.rs tests: family detection, endpoint reports, overrides.
module nano.vision_test;

@safe:

import std.json : parseJSON;
import std.typecons : Nullable;
import nano.attachment : DEFAULT_MAX_BYTES;
import nano.config : ProviderConfig, ProviderKind;
import nano.vision;

// rust: vision.rs::anthropic_vision_families_match_whole_segments
// rust: vision.rs::dotted_gpt5_revisions_are_vision_families
// rust: vision.rs::o1_family_is_vision_except_mini_and_preview
// rust: vision.rs::o3_mini_is_text_only_not_vision
// rust: vision.rs::openai_vision_families_match_whole_segments
unittest
{
    foreach (m; ["claude-3-opus-20240229", "claude-3-5-sonnet-20241022", "claude-3-7-sonnet", "claude-sonnet-4-5",
            "claude-opus-4-1", "claude-haiku-4-5", "ft:claude-3-5-sonnet:org::id", "claude-20-future", "claude-instantish"])
        assert(assumesAnthropicVision(m), m);
    foreach (m; ["claude-2", "claude-2.1", "claude-instant", "claude-instant-1.2"])
        assert(!assumesAnthropicVision(m), m);
    foreach (m; ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "gpt-5", "gpt-5-mini", "o3", "o4-mini",
            "ft:gpt-4o-2024-08-06:org::id", "gpt-5.1", "gpt-5.6", "gpt-5.6-sol", "ft:gpt-5.1:org::id",
            "o1", "o1-2024-12-17", "ft:o1:org::id"])
        assert(assumesOpenaiVision(m), m);
    foreach (m; ["gpt-4o3-custom", "text-embedding-3", "o3pro", "whisper-o4", "ft:gpt-3.5-turbo:org::o3", "gpt-50",
            "o3-mini", "o3-mini-2025-01-31", "ft:o3-mini:org::id", "o1-mini", "o1-mini-2024-09-12", "o1-preview",
            "o1-preview-2024-09-12", "ft:o1-mini:org::id", "o10"])
        assert(!assumesOpenaiVision(m), m);
}

// rust: vision.rs::copilot_entry_reads_vision_and_limits
// rust: vision.rs::ollama_and_llamacpp_detection
unittest
{
    auto v = Vision.fromModelEntry(parseJSON(`{"id":"gpt-5-mini","capabilities":{"supports":{"vision":true},"limits":{"vision":{
        "max_prompt_images":5,"max_prompt_image_size":3145728,"supported_media_types":["image/jpeg","image/png"]}}}}`));
    assert(v.get.maxImages == 5 && v.get.maxImageBytes == 3145728 && v.get.mediaTypes == ["image/jpeg", "image/png"]);
    auto bare = Vision.fromModelEntry(parseJSON(`{"capabilities":{"supports":{"vision":true}}}`));
    assert(bare.get.maxImages == 1 && bare.get.maxImageBytes == DEFAULT_MAX_BYTES && bare.get.mediaTypes.length == 0);
    assert(Vision.fromModelEntry(parseJSON(`{"capabilities":{"supports":{}}}`)).isNull);
    assert(Vision.fromOllamaShow(parseJSON(`{"capabilities":["completion"]}`)).isNull);
    assert(!Vision.fromOllamaShow(parseJSON(`{"capabilities":["vision","completion"]}`)).isNull);
    assert(Vision.fromLlamacppProps(parseJSON(`{"modalities":{"vision":false}}`)).isNull);
    assert(Vision.fromLlamacppProps(parseJSON(`{}`)).isNull);
}

// rust: vision.rs::forced_true_keeps_reported_endpoint_limits
// rust: vision.rs::per_model_override_is_most_specific
unittest
{
    import nano.config : ModelSettings;
    ProviderConfig plain;
    auto strict = Vision(2, 1_000_000, ["image/jpeg", "image/png"]);
    auto kept = resolve(Nullable!bool(true), ProviderKind.openai, plain, "copilot-model", &strict);
    assert(kept.get == strict, "forced-true keeps the endpoint's limits");
    assert(resolve(Nullable!bool(true), ProviderKind.openai, plain, "some-local").get == Vision.capable);
    assert(resolve(Nullable!bool(false), ProviderKind.openai, plain, "copilot-model", &strict).isNull);

    ProviderConfig p;
    p.vision = Nullable!bool(false);
    ModelSettings ms;
    ms.vision = Nullable!bool(true);
    p.models["m"] = ms;
    assert(configuredOverride(Nullable!bool.init, p, "m") == Override(Nullable!bool(true), Source.model));
    assert(configuredOverride(Nullable!bool.init, p, "other") == Override(Nullable!bool(false), Source.provider));
    assert(configuredOverride(Nullable!bool(true), plain, "m") == Override(Nullable!bool(true), Source.global));
    assert(configuredOverride(Nullable!bool.init, plain, "m").source == Source.detected);
}
