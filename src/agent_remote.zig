//! The shell half of the agent's view of the server: the HTTP transport under `RemoteStore`.
//! Shell code: it speaks HTTP. Everything else (building the requests, reading the replies, the
//! `Store` the agent core sees) is in `agent_client.zig`, which the cluster simulation runs over
//! its own network (`sim_net.zig`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const client_mod = @import("agent_client.zig");
const diag_mod = @import("diag.zig");
const http = @import("agent_http.zig");

pub const RemoteStore = client_mod.RemoteStore;

/// One request per connection over `http.Client`, with the failures the client already raises.
pub const HttpTransport = struct {
    client: http.Client,

    pub fn transport(self: *HttpTransport) client_mod.Transport {
        return .{ .context = self, .call_fn = call_impl };
    }

    fn call_impl(
        context: *anyopaque,
        arena: Allocator,
        request: client_mod.Request,
        diag: *diag_mod.Diag,
    ) client_mod.Error!client_mod.Reply {
        const self: *HttpTransport = @ptrCast(@alignCast(context));
        return self.client.call(arena, request, diag);
    }
};
