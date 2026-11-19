/// The image wire plan (llm.rs tests): the newest images within the quota
/// are sent; older intact ones say "sent earlier"; missing or tampered files
/// are placeholders that take no quota.
module nano.llm_attachments_test;
@safe:

version (unittest):

import std.algorithm : canFind;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.typecons : Nullable;
import nano.attachment : Attachment, fakePng, sha256Hex, store, storedFilename;
import nano.llm;
import nano.vision : Vision;

private:

string freshDir(string tag)
{
    auto d = buildPath(tempDir, "nano-llm-att-" ~ tag);
    if (exists(d)) rmdirRecurse(d);
    mkdirRecurse(d);
    return d;
}

/// A distinct PNG per `side`, stored under `dir` when given.
Attachment image(string tag, uint side, string dir = null)
{
    auto bytes = fakePng(side, side);
    Attachment a;
    a.mediaType = "image/png";
    a.path = "/tmp/" ~ tag ~ ".png";
    a.sha256 = sha256Hex(bytes);
    a.width = a.height = side;
    a.bytes = bytes.length;
    a.extension = "png";
    if (dir.length) store(dir, a, bytes);
    return a;
}

void tamper(string dir, const ref Attachment a) { write(buildPath(dir, storedFilename(a)), "tampered"); }

ChatRequest request(string dir, size_t maxImages, Attachment[][] perMessage...)
{
    ChatRequest r;
    foreach (i, atts; perMessage)
    {
        auto m = Message.toolResult("t" ~ cast(char)('1' + i), "read_file", "x");
        m.attachments = atts.dup;
        r.messages ~= m;
    }
    Vision v;
    v.maxImages = maxImages;
    r.vision = v;
    r.attachmentsDir = dir;
    return r;
}

ResolvedAttachment at(const ref ChatRequest r, size_t mi)
{
    auto plan = r.attachmentPlan;
    return r.resolveAttachments(mi, plan)[0];
}

// rust: llm.rs::resolves_newest_n_images_and_omits_the_rest
unittest
{
    auto dir = freshDir("newest");
    scope (exit) rmdirRecurse(dir);
    auto a = image("a", 11, dir), b = image("b", 12, dir), c = image("c", 13, dir);
    auto r = request(dir, 1, [a], [b], [c]);
    auto first = at(r, 0);
    assert(!first.isImage && first.text.canFind("omitted") && first.text.canFind("a.png"), first.text);
    assert(!at(r, 1).isImage && at(r, 2).isImage);
    assert(r.attachmentPlan.carriesImage);
    r = request(dir, 2, [a], [b], [c]);
    assert(!at(r, 0).isImage && at(r, 1).isImage && at(r, 2).isImage);
}

// rust: llm.rs::available_image_beyond_quota_says_sent_earlier
// rust: llm.rs::repeated_same_image_counts_each_occurrence_not_unique_hashes
unittest
{
    auto dir = freshDir("earlier");
    scope (exit) rmdirRecurse(dir);
    auto r = request(dir, 1, [image("a", 11, dir)], [image("b", 12, dir)]);
    assert(at(r, 0).text.canFind("sent earlier") && at(r, 1).isImage);
    auto dup = image("dup", 14, dir);
    r = request(dir, 1, [dup], [dup]);
    assert(!at(r, 0).isImage, "the older occurrence of a repeated image is omitted");
    assert(at(r, 1).isImage);
}

// rust: llm.rs::missing_attachment_file_becomes_a_placeholder
// rust: llm.rs::missing_newest_image_does_not_consume_quota_from_an_available_older_one
unittest
{
    auto dir = freshDir("missing");
    scope (exit) rmdirRecurse(dir);
    auto r = request(dir, 1, [image("gone", 15)]);
    auto gone = at(r, 0);
    assert(!gone.isImage && gone.text.canFind("gone.png") && gone.text.canFind("no longer available"), gone.text);
    assert(!r.attachmentPlan.carriesImage, "a deleted file reports no sendable image");

    r = request(dir, 1, [image("older", 16, dir)], [image("newest", 17)]);
    assert(at(r, 0).isImage, "the available older image fills the slot");
    auto newest = at(r, 1);
    assert(newest.text.canFind("no longer available") && !newest.text.canFind("sent earlier"), newest.text);
    assert(r.attachmentPlan.carriesImage);
}

// rust: llm.rs::tampered_newest_image_consumes_no_quota_and_sets_no_false_header
// rust: llm.rs::tampered_only_image_sets_no_vision_header
unittest
{
    auto dir = freshDir("tampered");
    scope (exit) rmdirRecurse(dir);
    auto older = image("older", 18, dir), newest = image("newest", 19, dir);
    tamper(dir, newest);
    auto r = request(dir, 1, [older], [newest]);
    assert(at(r, 0).isImage, "the intact older image fills the slot");
    auto t = at(r, 1);
    assert(t.text.canFind("no longer available") && !t.text.canFind("sent earlier"), t.text);
    assert(r.attachmentPlan.carriesImage);

    auto only = image("only", 20, dir);
    tamper(dir, only);
    r = request(dir, 1, [only]);
    assert(!at(r, 0).isImage && !r.attachmentPlan.carriesImage, "a tampered file reports no sendable image");
}

// rust: llm.rs::plan_carries_image_reflects_what_is_actually_sent
// rust: llm.rs::no_vision_sends_no_images
unittest
{
    auto dir = freshDir("carries");
    scope (exit) rmdirRecurse(dir);
    auto present = image("p", 21, dir), missing = image("m", 22);
    assert(request(dir, 1, [present]).attachmentPlan.carriesImage, "available image");
    assert(!request(dir, 1, [missing]).attachmentPlan.carriesImage, "missing file");
    assert(!request(dir, 0, [present]).attachmentPlan.carriesImage, "no image quota");
    assert(!request(dir, 1, cast(Attachment[]) []).attachmentPlan.carriesImage, "no attachments");
    auto blind = request(dir, 1, [present]);
    blind.vision = Nullable!Vision.init;
    assert(!blind.attachmentPlan.carriesImage && !at(blind, 0).isImage, "no vision");
}

// Attachments and trajectory fields (reasoning, usage, duration) round-trip
// through the session record; a plain message carries none of them.
// rust: llm.rs::attachments_round_trip_and_stay_off_plain_messages
// rust: llm.rs::trajectory_fields_round_trip_and_stay_out_of_plain_messages
unittest
{
    import std.json : parseJSON;
    import nano.session : messageFromRecord, messageRecord;
    auto m = Message.toolResult("c1", "read_file", "image/png, 10×10, 5 B");
    m.attachments = [image("a", 10)];
    auto j = messageRecord(m);
    assert(j["attachments"][0]["media_type"].str == "image/png" && j["attachments"][0]["width"].get!long == 10, j.toString);
    assert(messageFromRecord(j).attachments == m.attachments);

    auto t = Message.assistant("hi");
    t.thinking = "because";
    t.usage.inputTokens = 10;
    t.usage.outputTokens = 5;
    t.hasUsage = true;
    t.durationMs = 42;
    j = messageRecord(t);
    assert(j["thinking"].str == "because" && j["duration_ms"].get!long == 42, j.toString);
    assert(j["usage"] == parseJSON(`{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}`), j["usage"].toString);
    auto back = messageFromRecord(j);
    assert(back.thinking == "because" && back.hasUsage && back.usage.outputTokens == 5 && back.durationMs == 42);

    auto plain = Message.assistant("hi");
    assert(messageRecord(plain) == parseJSON(`{"role":"assistant","content":"hi"}`), messageRecord(plain).toString);
    assert(messageFromRecord(messageRecord(plain)).content == "hi");
}
