const std = @import("std");
const Allocator = std.mem.Allocator;

const X25519 = std.crypto.dh.X25519;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const max_message_size = 1024 * 1024;
pub const dcs_prefix = "\x1bP@kitty-cmd";
pub const dcs_suffix = "\x1b\\";
pub const encrypted_max_clock_skew_ns: i64 = 5 * 60 * std.time.ns_per_s;

pub const Request = struct {
    cmd: []const u8,
    argv: []const []const u8 = &.{},
    match: ?[]const u8 = null,
    match_tab: ?[]const u8 = null,
    all: bool = false,
    ignore_no_match: bool = false,
    no_response: bool = false,
    password: ?[]const u8 = null,
    timestamp: ?i64 = null,
    version: ?[]const u32 = null,
    kitty_window_id: ?i64 = null,
    async_request: bool = false,
    cancel_async: ?[]const u8 = null,
    stream: bool = false,
    stream_id: ?[]const u8 = null,
    response_timeout: ?u32 = null,
};

pub const ParseError = error{
    InvalidRequest,
    MissingCommand,
    MessageTooLarge,
};

pub const CryptoError = error{
    InvalidBase85,
    Base85Overflow,
    InvalidPublicKey,
    InvalidNonce,
    InvalidTag,
    InvalidTimestamp,
    MissingPassword,
    AuthenticationFailed,
};

/// Parsed request with allocator-owned memory.
pub const ParsedRequest = struct {
    arena: std.heap.ArenaAllocator,
    value: Request,

    pub fn deinit(self: *ParsedRequest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ParsedEncryptedEnvelope = struct {
    arena: std.heap.ArenaAllocator,
    version: ?[]const u32 = null,
    iv: []const u8,
    tag: []const u8,
    pubkey: []const u8,
    encrypted: []const u8,

    pub fn deinit(self: *ParsedEncryptedEnvelope) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ParsedWireRequest = union(enum) {
    plain: ParsedRequest,
    encrypted: ParsedEncryptedEnvelope,

    pub fn deinit(self: *ParsedWireRequest) void {
        switch (self.*) {
            .plain => |*v| v.deinit(),
            .encrypted => |*v| v.deinit(),
        }
        self.* = undefined;
    }
};

pub const ParsedPublicKey = struct {
    protocol_version: u32,
    public_key: [X25519.public_length]u8,
};

const WirePayload = struct {
    argv: []const []const u8 = &.{},
    args: []const []const u8 = &.{},
    keys: []const []const u8 = &.{},
    text: ?[]const u8 = null,
    data: ?[]const u8 = null,
    title: ?[]const u8 = null,
    match: ?[]const u8 = null,
    match_window: ?[]const u8 = null,
    match_tab: ?[]const u8 = null,
    ignore_no_match: bool = false,
    response_timeout: ?u32 = null,
};

const WireRequest = struct {
    cmd: []const u8,
    version: ?[]const u32 = null,
    no_response: bool = false,
    all: bool = false,
    match: ?[]const u8 = null,
    match_tab: ?[]const u8 = null,
    ignore_no_match: bool = false,
    password: ?[]const u8 = null,
    timestamp: ?i64 = null,
    kitty_window_id: ?i64 = null,
    async: bool = false,
    cancel_async: ?[]const u8 = null,
    stream: bool = false,
    stream_id: ?[]const u8 = null,
    response_timeout: ?u32 = null,
    payload: WirePayload = .{},
};

const WireEncryptedRequest = struct {
    version: ?[]const u32 = null,
    iv: []const u8,
    tag: []const u8,
    pubkey: []const u8,
    encrypted: []const u8,
};

fn collectArgv(alloc: Allocator, payload: WirePayload) Allocator.Error![]const []const u8 {
    if (payload.argv.len > 0) return payload.argv;
    if (payload.args.len > 0) return payload.args;
    if (payload.keys.len > 0) return payload.keys;

    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(alloc);

    if (payload.data) |data| {
        if (std.mem.startsWith(u8, data, "base64:")) {
            const raw = data["base64:".len..];
            if (raw.len > 0) {
                const decoded = decodeBase64ToOwned(alloc, raw) catch null;
                if (decoded) |value| {
                    try list.append(alloc, value);
                } else {
                    try list.append(alloc, raw);
                }
            } else {
                try list.append(alloc, "");
            }
        } else if (std.mem.startsWith(u8, data, "text:")) {
            try list.append(alloc, data["text:".len..]);
        } else {
            try list.append(alloc, data);
        }
    }

    if (payload.text) |text| try list.append(alloc, text);
    if (payload.title) |title| try list.append(alloc, title);

    return try list.toOwnedSlice(alloc);
}

fn decodeBase64ToOwned(alloc: Allocator, raw: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(raw);
    const out = try alloc.alloc(u8, size);
    errdefer alloc.free(out);
    try decoder.decode(out, raw);
    return out;
}

pub fn isDcsFrame(message: []const u8) bool {
    const trimmed = std.mem.trim(u8, message, " \r\n\t");
    return std.mem.startsWith(u8, trimmed, dcs_prefix) and std.mem.endsWith(u8, trimmed, dcs_suffix);
}

pub fn unwrapFrame(message: []const u8) ParseError![]const u8 {
    const trimmed = std.mem.trim(u8, message, " \r\n\t");
    if (trimmed.len == 0) return error.InvalidRequest;
    if (!std.mem.startsWith(u8, trimmed, dcs_prefix)) return trimmed;
    if (!std.mem.endsWith(u8, trimmed, dcs_suffix)) return error.InvalidRequest;
    return trimmed[dcs_prefix.len .. trimmed.len - dcs_suffix.len];
}

pub fn wrapFrame(
    alloc: Allocator,
    payload: []const u8,
) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, dcs_prefix);
    try out.appendSlice(alloc, payload);
    try out.appendSlice(alloc, dcs_suffix);
    return out.toOwnedSlice(alloc);
}

fn parsePlainPayload(alloc: Allocator, payload: []const u8) ParseError!ParsedRequest {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();
    const payload_copy = arena_alloc.dupe(u8, payload) catch return error.InvalidRequest;

    var parsed = std.json.parseFromSlice(WireRequest, arena_alloc, payload_copy, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidRequest;
    defer parsed.deinit();

    if (parsed.value.cmd.len == 0) return error.MissingCommand;

    const argv = collectArgv(arena_alloc, parsed.value.payload) catch return error.InvalidRequest;

    return .{
        .arena = arena,
        .value = .{
            .cmd = parsed.value.cmd,
            .argv = argv,
            .match = parsed.value.match orelse parsed.value.payload.match orelse parsed.value.payload.match_window,
            .match_tab = parsed.value.match_tab orelse parsed.value.payload.match_tab,
            .all = parsed.value.all,
            .ignore_no_match = parsed.value.ignore_no_match or parsed.value.payload.ignore_no_match,
            .no_response = parsed.value.no_response,
            .password = parsed.value.password,
            .timestamp = parsed.value.timestamp,
            .version = parsed.value.version,
            .kitty_window_id = parsed.value.kitty_window_id,
            .async_request = parsed.value.async,
            .cancel_async = parsed.value.cancel_async,
            .stream = parsed.value.stream,
            .stream_id = parsed.value.stream_id,
            .response_timeout = parsed.value.response_timeout orelse parsed.value.payload.response_timeout,
        },
    };
}

fn parseEncryptedPayload(alloc: Allocator, payload: []const u8) ParseError!ParsedEncryptedEnvelope {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();
    const payload_copy = arena_alloc.dupe(u8, payload) catch return error.InvalidRequest;

    var parsed = std.json.parseFromSlice(WireEncryptedRequest, arena_alloc, payload_copy, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidRequest;
    defer parsed.deinit();

    if (parsed.value.iv.len == 0 or
        parsed.value.tag.len == 0 or
        parsed.value.pubkey.len == 0 or
        parsed.value.encrypted.len == 0)
    {
        return error.InvalidRequest;
    }

    return .{
        .arena = arena,
        .version = parsed.value.version,
        .iv = parsed.value.iv,
        .tag = parsed.value.tag,
        .pubkey = parsed.value.pubkey,
        .encrypted = parsed.value.encrypted,
    };
}

pub fn parseWireRequest(alloc: Allocator, message: []const u8) ParseError!ParsedWireRequest {
    if (message.len == 0 or message.len > max_message_size) return error.MessageTooLarge;
    const payload = try unwrapFrame(message);

    var probe = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch return error.InvalidRequest;
    defer probe.deinit();
    if (probe.value != .object) return error.InvalidRequest;

    const obj = probe.value.object;
    if (obj.get("cmd") != null) {
        return .{ .plain = try parsePlainPayload(alloc, payload) };
    }

    if (obj.get("iv") != null and obj.get("tag") != null and obj.get("pubkey") != null and obj.get("encrypted") != null) {
        return .{ .encrypted = try parseEncryptedPayload(alloc, payload) };
    }

    return error.InvalidRequest;
}

pub fn parseRequest(alloc: Allocator, message: []const u8) ParseError!ParsedRequest {
    if (message.len == 0 or message.len > max_message_size) return error.MessageTooLarge;
    const payload = try unwrapFrame(message);
    return parsePlainPayload(alloc, payload);
}

pub fn encodeRequest(
    alloc: Allocator,
    req: Request,
) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(alloc, .{
        .cmd = req.cmd,
        .version = .{ 0, 26, 0 },
        .no_response = req.no_response,
        .all = req.all,
        .match = req.match,
        .match_tab = req.match_tab,
        .ignore_no_match = req.ignore_no_match,
        .password = req.password,
        .timestamp = req.timestamp,
        .kitty_window_id = req.kitty_window_id,
        .async = req.async_request,
        .cancel_async = req.cancel_async,
        .stream = req.stream,
        .stream_id = req.stream_id,
        .response_timeout = req.response_timeout,
        .payload = .{
            .argv = req.argv,
            .response_timeout = req.response_timeout,
        },
    }, .{});
}

pub fn encodeOk(
    alloc: Allocator,
    data: anytype,
) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(alloc, .{
        .ok = true,
        .data = data,
    }, .{});
}

pub fn encodeError(
    alloc: Allocator,
    message: []const u8,
) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(alloc, .{
        .ok = false,
        .@"error" = message,
    }, .{});
}

fn deriveAesKey(shared_secret: [X25519.shared_length]u8) [Aes256Gcm.key_length]u8 {
    var out: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(&shared_secret, &out, .{});
    return out;
}

const b85_alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+-;<=>?@^_`{|}~";

fn b85Digit(c: u8) ?u8 {
    const idx = std.mem.indexOfScalar(u8, b85_alphabet, c) orelse return null;
    return @intCast(idx);
}

pub fn encodeBase85Alloc(alloc: Allocator, data: []const u8) Allocator.Error![]u8 {
    if (data.len == 0) return alloc.alloc(u8, 0);

    const padding = (4 - (data.len % 4)) % 4;
    const groups = (data.len + padding) / 4;
    const out_len = groups * 5 - padding;

    var out = try alloc.alloc(u8, out_len);
    var in_idx: usize = 0;
    var out_idx: usize = 0;

    var g: usize = 0;
    while (g < groups) : (g += 1) {
        var chunk = [_]u8{0} ** 4;
        const remaining = data.len - in_idx;
        const take = @min(remaining, 4);
        @memcpy(chunk[0..take], data[in_idx .. in_idx + take]);
        in_idx += take;

        var value = std.mem.readInt(u32, &chunk, .big);
        var digits: [5]u8 = undefined;
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const rev_idx = 4 - i;
            digits[rev_idx] = b85_alphabet[value % 85];
            value /= 85;
        }

        const emit = if (g + 1 == groups and padding > 0) 5 - padding else 5;
        @memcpy(out[out_idx .. out_idx + emit], digits[0..emit]);
        out_idx += emit;
    }

    return out;
}

pub fn decodeBase85Alloc(alloc: Allocator, encoded: []const u8) (Allocator.Error || CryptoError)![]u8 {
    if (encoded.len == 0) return alloc.alloc(u8, 0);

    const padding = (5 - (encoded.len % 5)) % 5;
    const groups = (encoded.len + padding) / 5;
    const out_len = groups * 4 - padding;

    var out = try alloc.alloc(u8, out_len);
    var out_idx: usize = 0;

    var g: usize = 0;
    while (g < groups) : (g += 1) {
        var chunk: [5]u8 = undefined;
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const idx = g * 5 + i;
            chunk[i] = if (idx < encoded.len) encoded[idx] else '~';
        }

        var acc: u64 = 0;
        for (chunk) |c| {
            const d = b85Digit(c) orelse return error.InvalidBase85;
            acc = acc * 85 + d;
        }

        if (acc > std.math.maxInt(u32)) return error.Base85Overflow;

        var block: [4]u8 = undefined;
        std.mem.writeInt(u32, &block, @intCast(acc), .big);

        const emit = if (g + 1 == groups and padding > 0) 4 - padding else 4;
        @memcpy(out[out_idx .. out_idx + emit], block[0..emit]);
        out_idx += emit;
    }

    return out;
}

pub fn encodeKittyPublicKey(
    alloc: Allocator,
    protocol_version: u32,
    public_key: [X25519.public_length]u8,
) Allocator.Error![]u8 {
    const b85 = try encodeBase85Alloc(alloc, &public_key);
    defer alloc.free(b85);
    return std.fmt.allocPrint(alloc, "{d}:{s}", .{ protocol_version, b85 });
}

pub fn decodeKittyPublicKey(
    alloc: Allocator,
    encoded_value: []const u8,
) (Allocator.Error || CryptoError)!ParsedPublicKey {
    var version: u32 = 1;
    var key_value = encoded_value;

    if (std.mem.indexOfScalar(u8, encoded_value, ':')) |idx| {
        version = std.fmt.parseUnsigned(u32, encoded_value[0..idx], 10) catch return error.InvalidPublicKey;
        if (idx + 1 >= encoded_value.len) return error.InvalidPublicKey;
        key_value = encoded_value[idx + 1 ..];
    }

    const decoded = try decodeBase85Alloc(alloc, key_value);
    defer alloc.free(decoded);

    if (decoded.len != X25519.public_length) return error.InvalidPublicKey;

    var key: [X25519.public_length]u8 = undefined;
    @memcpy(&key, decoded[0..X25519.public_length]);
    return .{
        .protocol_version = version,
        .public_key = key,
    };
}

pub fn encryptRequestForServer(
    alloc: Allocator,
    request_json: []const u8,
    server_public_key: [X25519.public_length]u8,
) (Allocator.Error || CryptoError)![]u8 {
    const keypair = X25519.KeyPair.generate();
    const shared = X25519.scalarmult(keypair.secret_key, server_public_key) catch return error.InvalidPublicKey;
    const aes_key = deriveAesKey(shared);

    var nonce: [Aes256Gcm.nonce_length]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    const ciphertext = try alloc.alloc(u8, request_json.len);
    defer alloc.free(ciphertext);

    var tag: [Aes256Gcm.tag_length]u8 = undefined;
    Aes256Gcm.encrypt(ciphertext, &tag, request_json, "", nonce, aes_key);

    const iv_b85 = try encodeBase85Alloc(alloc, &nonce);
    defer alloc.free(iv_b85);

    const tag_b85 = try encodeBase85Alloc(alloc, &tag);
    defer alloc.free(tag_b85);

    const pub_b85 = try encodeBase85Alloc(alloc, &keypair.public_key);
    defer alloc.free(pub_b85);

    const enc_b85 = try encodeBase85Alloc(alloc, ciphertext);
    defer alloc.free(enc_b85);

    return std.json.Stringify.valueAlloc(alloc, .{
        .version = .{ 0, 26, 0 },
        .iv = iv_b85,
        .tag = tag_b85,
        .pubkey = pub_b85,
        .encrypted = enc_b85,
    }, .{});
}

pub fn decryptRequestEnvelope(
    alloc: Allocator,
    envelope: ParsedEncryptedEnvelope,
    server_secret_key: [X25519.secret_length]u8,
) (Allocator.Error || CryptoError || ParseError)!ParsedRequest {
    const iv_raw = try decodeBase85Alloc(alloc, envelope.iv);
    defer alloc.free(iv_raw);
    if (iv_raw.len != Aes256Gcm.nonce_length) return error.InvalidNonce;

    var nonce: [Aes256Gcm.nonce_length]u8 = undefined;
    @memcpy(&nonce, iv_raw[0..Aes256Gcm.nonce_length]);

    const tag_raw = try decodeBase85Alloc(alloc, envelope.tag);
    defer alloc.free(tag_raw);
    if (tag_raw.len != Aes256Gcm.tag_length) return error.InvalidTag;

    var tag: [Aes256Gcm.tag_length]u8 = undefined;
    @memcpy(&tag, tag_raw[0..Aes256Gcm.tag_length]);

    const pub_raw = try decodeBase85Alloc(alloc, envelope.pubkey);
    defer alloc.free(pub_raw);
    if (pub_raw.len != X25519.public_length) return error.InvalidPublicKey;

    var client_pub: [X25519.public_length]u8 = undefined;
    @memcpy(&client_pub, pub_raw[0..X25519.public_length]);

    const ciphertext = try decodeBase85Alloc(alloc, envelope.encrypted);
    defer alloc.free(ciphertext);

    const shared = X25519.scalarmult(server_secret_key, client_pub) catch return error.InvalidPublicKey;
    const aes_key = deriveAesKey(shared);

    const plaintext = try alloc.alloc(u8, ciphertext.len);
    defer alloc.free(plaintext);

    Aes256Gcm.decrypt(plaintext, ciphertext, tag, "", nonce, aes_key) catch return error.AuthenticationFailed;

    var parsed = try parsePlainPayload(alloc, plaintext);

    const timestamp = parsed.value.timestamp orelse {
        parsed.deinit();
        return error.InvalidTimestamp;
    };

    const now = std.time.nanoTimestamp();
    const delta: i128 = @as(i128, timestamp) - now;
    const abs_delta: i128 = if (delta < 0) -delta else delta;
    if (abs_delta > encrypted_max_clock_skew_ns) {
        parsed.deinit();
        return error.InvalidTimestamp;
    }

    const password = parsed.value.password orelse {
        parsed.deinit();
        return error.MissingPassword;
    };
    if (password.len == 0) {
        parsed.deinit();
        return error.MissingPassword;
    }

    return parsed;
}

test "encodeRequest includes command and argv" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const req: Request = .{
        .cmd = "set-window-title",
        .argv = &.{ "hello", "world" },
        .match = "id:4",
        .all = false,
    };
    const encoded = try encodeRequest(alloc, req);
    defer alloc.free(encoded);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqualStrings("set-window-title", obj.get("cmd").?.string);
    try testing.expectEqualStrings("id:4", obj.get("match").?.string);
    try testing.expect(obj.get("payload").?.object.get("argv").? == .array);
}

test "encodeRequest roundtrip preserves remote-control request fields" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const req: Request = .{
        .cmd = "send-text",
        .argv = &.{ "echo", "hello" },
        .match = "id:4",
        .match_tab = "title:demo",
        .all = true,
        .ignore_no_match = true,
        .no_response = true,
        .password = "demo-secret",
        .timestamp = 123456789,
        .kitty_window_id = 7,
        .async_request = true,
        .cancel_async = "req-1",
        .stream = true,
        .stream_id = "stream-1",
        .response_timeout = 13,
    };

    const encoded = try encodeRequest(alloc, req);
    defer alloc.free(encoded);

    var parsed = try parseRequest(alloc, encoded);
    defer parsed.deinit();

    try testing.expectEqualStrings("send-text", parsed.value.cmd);
    try testing.expectEqual(@as(usize, 2), parsed.value.argv.len);
    try testing.expectEqualStrings("echo", parsed.value.argv[0]);
    try testing.expectEqualStrings("hello", parsed.value.argv[1]);
    try testing.expectEqualStrings("id:4", parsed.value.match.?);
    try testing.expectEqualStrings("title:demo", parsed.value.match_tab.?);
    try testing.expect(parsed.value.all);
    try testing.expect(parsed.value.ignore_no_match);
    try testing.expect(parsed.value.no_response);
    try testing.expectEqualStrings("demo-secret", parsed.value.password.?);
    try testing.expectEqual(@as(i64, 123456789), parsed.value.timestamp.?);
    try testing.expect(parsed.value.version != null);
    try testing.expectEqual(@as(u32, 0), parsed.value.version.?[0]);
    try testing.expectEqual(@as(u32, 26), parsed.value.version.?[1]);
    try testing.expectEqual(@as(u32, 0), parsed.value.version.?[2]);
    try testing.expectEqual(@as(i64, 7), parsed.value.kitty_window_id.?);
    try testing.expect(parsed.value.async_request);
    try testing.expectEqualStrings("req-1", parsed.value.cancel_async.?);
    try testing.expect(parsed.value.stream);
    try testing.expectEqualStrings("stream-1", parsed.value.stream_id.?);
    try testing.expectEqual(@as(u32, 13), parsed.value.response_timeout.?);
}

test "parseRequest accepts payload argv" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var parsed = try parseRequest(
        alloc,
        "{\"cmd\":\"send-text\",\"match\":\"state:focused\",\"payload\":{\"argv\":[\"hello\"]}}",
    );
    defer parsed.deinit();

    try testing.expectEqualStrings("send-text", parsed.value.cmd);
    try testing.expectEqualStrings("state:focused", parsed.value.match.?);
    try testing.expectEqual(@as(usize, 1), parsed.value.argv.len);
    try testing.expectEqualStrings("hello", parsed.value.argv[0]);
}

test "parseWireRequest distinguishes plain vs encrypted" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var plain = try parseWireRequest(alloc, "{\"cmd\":\"ls\"}");
    defer plain.deinit();
    try testing.expect(plain == .plain);

    var enc = try parseWireRequest(
        alloc,
        "{\"version\":[0,26,0],\"iv\":\"00\",\"tag\":\"00\",\"pubkey\":\"00\",\"encrypted\":\"00\"}",
    );
    defer enc.deinit();
    try testing.expect(enc == .encrypted);
}

test "parseRequest accepts extended kitty request fields" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var parsed = try parseRequest(
        alloc,
        "{\"cmd\":\"ls\",\"version\":[0,45,0],\"match_tab\":\"title:demo\",\"ignore_no_match\":true,\"kitty_window_id\":7,\"async\":true,\"cancel_async\":\"r1\",\"stream\":true,\"stream_id\":\"s1\"}",
    );
    defer parsed.deinit();

    try testing.expect(parsed.value.version != null);
    try testing.expectEqual(@as(u32, 45), parsed.value.version.?[1]);
    try testing.expectEqualStrings("title:demo", parsed.value.match_tab.?);
    try testing.expect(parsed.value.ignore_no_match);
    try testing.expectEqual(@as(i64, 7), parsed.value.kitty_window_id.?);
    try testing.expect(parsed.value.async_request);
    try testing.expectEqualStrings("r1", parsed.value.cancel_async.?);
    try testing.expect(parsed.value.stream);
    try testing.expectEqualStrings("s1", parsed.value.stream_id.?);
}

test "parseRequest accepts response-timeout in payload" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var parsed = try parseRequest(
        alloc,
        "{\"cmd\":\"select-window\",\"payload\":{\"response_timeout\":1}}",
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(u32, 1), parsed.value.response_timeout.?);
}

test "parseRequest supports payload text fallback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var parsed = try parseRequest(
        alloc,
        "{\"cmd\":\"send-text\",\"payload\":{\"text\":\"hello world\"}}",
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 1), parsed.value.argv.len);
    try testing.expectEqualStrings("hello world", parsed.value.argv[0]);
}

test "parseRequest supports payload match fields" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var parsed = try parseRequest(
        alloc,
        "{\"cmd\":\"ls\",\"payload\":{\"match_window\":\"id:9\",\"match_tab\":\"title:demo\",\"ignore_no_match\":true}}",
    );
    defer parsed.deinit();

    try testing.expectEqualStrings("id:9", parsed.value.match.?);
    try testing.expectEqualStrings("title:demo", parsed.value.match_tab.?);
    try testing.expect(parsed.value.ignore_no_match);
}

test "wrapFrame and unwrapFrame roundtrip" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const payload = "{\"ok\":true}";
    const framed = try wrapFrame(alloc, payload);
    defer alloc.free(framed);

    try testing.expect(isDcsFrame(framed));
    const unwrapped = try unwrapFrame(framed);
    try testing.expectEqualStrings(payload, unwrapped);
}

test "base85 roundtrip" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const raw = "hello kitty base85";
    const encoded = try encodeBase85Alloc(alloc, raw);
    defer alloc.free(encoded);

    const decoded = try decodeBase85Alloc(alloc, encoded);
    defer alloc.free(decoded);

    try testing.expectEqualStrings(raw, decoded);
}

test "decodeKittyPublicKey parses versioned format" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const parsed = try decodeKittyPublicKey(alloc, "1:p%e)!ISuc!FG$OF)p&7252OB&74NXeUFpxWbfNZp");
    try testing.expectEqual(@as(u32, 1), parsed.protocol_version);
}

test "encryptRequestForServer + decryptRequestEnvelope roundtrip" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const server_keypair = X25519.KeyPair.generate();
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());

    const request = try encodeRequest(alloc, .{
        .cmd = "ls",
        .password = "demo",
        .timestamp = now_ns,
    });
    defer alloc.free(request);

    const envelope = try encryptRequestForServer(alloc, request, server_keypair.public_key);
    defer alloc.free(envelope);

    var wire = try parseWireRequest(alloc, envelope);
    defer wire.deinit();
    try testing.expect(wire == .encrypted);

    var decrypted = try decryptRequestEnvelope(alloc, wire.encrypted, server_keypair.secret_key);
    defer decrypted.deinit();

    try testing.expectEqualStrings("ls", decrypted.value.cmd);
    try testing.expectEqualStrings("demo", decrypted.value.password.?);
    try testing.expect(decrypted.value.timestamp != null);
}

test "parseRequest rejects missing command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    try testing.expectError(
        error.MissingCommand,
        parseRequest(alloc, "{\"cmd\":\"\"}"),
    );
}

test "parseRequest fuzz malformed payload corpus" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const corpus = [_][]const u8{
        "{",
        "[]",
        "{\"cmd\":1}",
        "{\"cmd\":\"ls\",\"payload\":1}",
        "{\"cmd\":\"ls\",\"all\":\"yes\"}",
        "{\"cmd\":\"ls\",\"match\":12}",
        "{\"cmd\":\"ls\",\"match_tab\":12}",
        "{\"cmd\":\"ls\",\"ignore_no_match\":\"true\"}",
        "{\"cmd\":\"ls\",\"version\":\"0.45.0\"}",
        "{\"cmd\":\"ls\",\"kitty_window_id\":\"7\"}",
        "{\"cmd\":\"ls\",\"async\":\"true\"}",
        "{\"cmd\":\"ls\",\"stream\":\"true\"}",
        "{\"cmd\":\"ls\",\"payload\":{\"argv\":\"ls\"}}",
    };

    for (corpus) |sample| {
        var parsed = parseRequest(alloc, sample) catch continue;
        parsed.deinit();
    }
}

test "parseRequest fuzz random bytes does not panic" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var prng = std.Random.DefaultPrng.init(0x8fd5_a2c9_1193_7b43);
    const random = prng.random();

    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const len: usize = random.uintLessThan(usize, 256);
        const data = try alloc.alloc(u8, len);
        defer alloc.free(data);
        random.bytes(data);

        var parsed = parseRequest(alloc, data) catch continue;
        parsed.deinit();
    }
}
