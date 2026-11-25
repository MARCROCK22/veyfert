# Known V issues

veyfert works around these issues of V and its standard library. Each has an issue upstream, or a
note on why it has none yet; [PLAN.md](PLAN.md#7-risks-and-v-gaps-found) has the evidence and the
details.

## The compiler

- `v fmt` flattens field attributes that take several arguments
  ([vlang/v#32875](https://github.com/vlang/v/issues/32875)), so field attributes take one value
  each: `@[veyfert.Min: 1]`, never `@[Range(min: 1, max: 10)]`.
- A generic call under `$if a is Schema` is instantiated for every field
  ([vlang/v#32876](https://github.com/vlang/v/issues/32876)), so guards are found by their type;
  `v -check` misses a `$compile_error` in those branches
  ([vlang/v#32877](https://github.com/vlang/v/issues/32877)). That is also why
  `tests/check_docs.vsh` builds the examples instead of only checking them.
- A flag enum's built-in `zero()` is not found through a module prefix
  ([vlang/v#32882](https://github.com/vlang/v/issues/32882)), so `discord.no_permissions()`
  exists.
- Appending a struct that implements `IError` to an `[]IError` with `<<` stores a broken
  interface, and `msg()` on it panics ([vlang/v#32893](https://github.com/vlang/v/issues/32893)).
  veyfert casts first: `failures << IError(PluginError{...})`.
- In veyfert's builds, some generated C takes another expression's type or name: a generic method
  that only the library calls, and `time.now()` in `net.http.Server`'s `DebugHandler`. A minimal
  program does not show it, so it is not reported yet. veyfert avoids both: the library does not
  call its own event generics, and `veyfert.server` has its own small HTTP/1.1 server.
- A function type declares an enum backed by `u64` as C `int`
  ([vlang/v#32915](https://github.com/vlang/v/issues/32915)), so a `discord.Permissions` with
  permissions past bit 31, such as `moderate_members`, arrives as 0 through a callback or a
  closure. veyfert calls its permission hooks through a function type that takes `u64`; in your
  own callbacks, pass `u64(perms)` and convert it back.
- In a struct literal, a pointer is not turned into an optional interface field:
  `cache.Options{adapter: store}` fails, and `adapter: cache.Adapter(store)` works.

## json2

- `json2` writes `@[raw]` fields back as strings
  ([vlang/v#32879](https://github.com/vlang/v/issues/32879)), hence `discord.RawJson`.
- `json2.Null` in a sum type comes out as `{"_type":"Null"}`
  ([vlang/v#32880](https://github.com/vlang/v/issues/32880)), hence `discord.Nullable[T]`.
- Sum types are discriminated only by a `"_type"` key, so Discord's unions are flat structs or
  `discord.RawJson`.

## net.websocket

- It reports one close twice ([vlang/v#32878](https://github.com/vlang/v/issues/32878)), so a
  shard keeps the first report of each connection.
- It uses V's global `rand` generator, which is not thread safe, to mask frames, name clients and
  make handshake keys ([vlang/v#32886](https://github.com/vlang/v/issues/32886)). veyfert itself
  uses `crypto.rand`.
- `TcpConn.read` copies the connection while another thread writes to it
  ([vlang/v#32888](https://github.com/vlang/v/issues/32888)).
- `Client.close()` closes the socket while `listen()` reads from it
  ([vlang/v#32887](https://github.com/vlang/v/issues/32887)).
- Its server binds every interface, so `veyfert.testing` has its own on 127.0.0.1, and Windows
  does not ask about the firewall on every test run.
- Over `wss://`, it reads the TLS connection on one thread while others write to it, which neither
  TLS backend supports, as [vlang/v#31772](https://github.com/vlang/v/issues/31772) explains.
  The gateway sends heartbeats and payloads that way, and veyfert has no workaround yet: doing it
  safely needs non-blocking TLS with a lock, which belongs in `net.ssl`.

## Running with -race

`-race` does not exist on Windows; veyfert's CI runs it on Linux and macOS. `tests/tsan.supp`
suppresses only the races inside `net.websocket` listed above. Use it for veyfert or for your
bot:

```sh
TSAN_OPTIONS="suppressions=<path to veyfert>/tests/tsan.supp" v -race test .
```
