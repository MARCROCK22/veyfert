# Plan: veyfert, un framework de bots de Discord en V al estilo de Seyfert

> Base del análisis: **Seyfert 6.0.0** (commit `ac6e8e9`, 23-11-2026, código fuente completo), **V 0.5.2**
> (`0a43261`, el master instalado en `C:\v`) y la **API v10 de Discord**.
>
> Leyenda: ✅ verificado con una sonda compilada y ejecutada · 📖 leído en la documentación o el código
> de V · 🧪 pendiente de comprobar con un spike.

## 0. Resumen

- **Enfoque "comptime-first".** Comandos, opciones, guards, componentes, modales y eventos son *structs*
  de V con atributos tipados (`@[attribute]`). La reflexión en compilación genera el JSON que pide Discord
  y vuelca cada payload en campos tipados. Así se sustituyen los decoradores, la inferencia de tipos de TS
  y los `Proxy` de JS, y los errores de definición aparecen al compilar.
- **Módulos por capa** (decidido el 24-11-2026; antes era un solo módulo). En V cada carpeta es un
  módulo, no hay re-exports y los imports no pueden formar ciclos. Las capas que no dependen del
  cliente van en submódulos que el núcleo importa:
  - `veyfert.discord`: tipos, eventos y componentes;
  - `veyfert.rest`: HTTP y rate limits, con `veyfert.rest.api` (el REST generado);
  - `veyfert.cache`.

  Lo opcional (`server`, `testing`, `plugins`) importa `veyfert` en un solo sentido. Un bot escribe
  `import veyfert` y `import veyfert.discord`. Una fachada con alias de tipo no sirve: el alias pierde
  los atributos `@[Event]`, y `$if field.typ is Alias` no coincide.
- **Hilos en vez de async/await.** Cada shard tiene un hilo lector, y como una guild siempre cae en el
  mismo shard, el orden por guild sale gratis. El código del usuario corre en un pool acotado. Bloquear
  está permitido, así que `wait_for` sustituye a los colectores con callbacks. Con esto desaparece la
  razón de ser de `WorkerManager`.
- **Discord y V hablan snake_case.** V prohíbe mayúsculas en los nombres de campo (✅), así que los modelos
  reflejan el JSON de Discord tal cual. La capa camelCase y los `Transformers` de Seyfert no hacen falta.
- **Modelos REST generados** desde la spec OpenAPI oficial de Discord. Los payloads del gateway se
  escriben a mano.
- **Ocho fases**, cada una con un criterio de salida comprobable. La fase 0 es un spike vertical que
  valida todo esto con un bot real.

## 1. Análisis de Seyfert

### 1.1 Tamaño

Tiene 315 archivos TypeScript y 51 280 líneas, de las que 15 819 son tipos de la API de Discord.
Exporta 541 símbolos de runtime (213 clases, 208 funciones, 110 constantes y 10 enums). Los tests ocupan
unos 80 archivos: Vitest más contratos de tipos compilados con `tsc`.

### 1.2 Inventario por subsistema

| Subsistema | Qué ofrece | Líneas |
|---|---|---|
| `client/` | `BaseClient`, `Client` (gateway), `HttpClient`, `WorkerClient`; `start()`, `uploadCommands()` y `close()`; `setServices` (rest, cache, langs, middlewares, handleCommand); defaults de comandos, componentes y modales; `allowedMentions`; presence por shard; rango de shards; colectores de eventos (filter, idle, timeout); `Transformers` para estructuras propias | ~3 200 |
| Plugins | `createPlugin`/`definePlugins` con ciclo `register → setup → teardown` (este último en orden inverso), `imports`, `requires` (semver) y extensiones de cliente y de contexto. Pueden aportar comandos, componentes, modales, eventos, middlewares y wrappers de middleware y de autocomplete. También observadores de comandos y de REST, interceptores de dispatch y de envío al gateway, hooks (`commands:beforeLoad`, `plugins:ready`, `client:close`…), recursos de caché, langs y un registro `shared` tipado. Los plugins tienen orden y diagnósticos | ~3 900 |
| `commands/` | `Command`, `SubCommand`, `ContextMenuCommand` y `EntryPointCommand`. Decoradores `@Declare` (name, description, botPermissions, defaultMemberPermissions, guildId, nsfw, integrationTypes, contexts, ignore, aliases, props), `@Options`, `@Group(s)`, `@AutoLoad`, `@Middlewares` y `@Locales(T)`. Nueve tipos de opción con required, choices, min/max, channel_types, autocomplete y transformadores `value(ok, fail)`. Nueve hooks por comando además de `run`. Comandos por prefijo con parser de argumentos y alias. Contextos: `write`, `deferReply`, `editResponse`, `deleteResponse`, `editOrReply`, `followup`, `fetchResponse`, `modal`, `author`, `member`, `guild()`, `channel()`, `me()`, `t` y `metadata` | 3 650 |
| `components/` | Componentes recibidos (incluidos los v2), `ComponentCommand` (customId como string o RegExp, filter), `ModalCommand`, `ModalContext` (inputs, canales, roles, usuarios, radio, checkbox, archivos) y colectores de componentes con idle y timeout | 1 760 |
| `builders/` | Embed, botones, action rows, cinco select menus, Modal/TextInput, Poll y adjuntos (URL, ruta, buffer o base64). Components v2: Container, Section, TextDisplay, MediaGallery, File, Separator, Thumbnail y Label. Además FileUpload, Checkbox(Group) y RadioGroup, con validación y errores tipados | 2 270 |
| `api/` | REST sobre `fetch` con buckets aprendidos (`x-ratelimit-bucket` + parámetro mayor), 429 global por token, exención de `/interactions`, tres reintentos ante 502/503, multipart, `X-Audit-Log-Reason` y observadores. Router tipado vía `Proxy` (`client.proxy.channels(id).messages.post()`) y router de CDN | 2 290 |
| Shorters | 19 clases y ~160 métodos (`client.messages.write`, `client.members.ban`…) que siguen el camino REST → caché → estructura | 2 910 |
| `cache/` | 13 recursos: users, guilds, members, voiceStates, presences, bans, roles, overwrites, channels, emojis, stickers, stageInstances y messages. Sensible a intents, desactivable por recurso, con paginación y búsqueda desde caché y conteo de miembros con cola ordenada por guild. Adaptadores Memory, LimitedMemory (límite y expiración por recurso) y Worker, con suite de conformidad | 3 060 |
| `structures/` | ~30 estructuras con métodos: Guild, Member, User, Message, 20 clases de canal (con mixins), 17 de interacción, etc. Incluye BitField y PermissionsBitField | 4 190 |
| `events/` | Carga desde carpeta, ~80 eventos del gateway y 8 propios (BOT_READY, GUILDS_READY, SHARD_DISCONNECT/RECONNECT, WORKER_*…). La caché se muta antes que los listeners. Soporta `once` y recarga | 1 200 |
| `websocket/` | `Shard`: heartbeat con detección de zombi, resume o identify, política por close code, cola de envío offline, límite de 120 envíos por 60 s y `requestGuildMembers` por nonce con reintento ante RATE_LIMITED. `ShardManager`: cola de identify por `max_concurrency`, resharding, presence y voz. También un socket propio para Node y `WorkerManager` (threads, clusters o custom, proxy de REST y hot reload por generaciones con traspaso de sesión) | 4 040 |
| `langs/` | Carga por carpeta, alias de locale, `preferGuildLocale` y acceso tipado `ctx.t.ruta.clave(args).get()` vía `Proxy` | 210 |
| Utilidades | `Logger`, `Formatter` (markdown, menciones, timestamps, URL OAuth2), `SeyfertError` (~80 códigos estables con metadata y `cause`), `Collection`/`LimitedCollection` y un watcher de desarrollo | ~2 600 |

### 1.3 Contratos de comportamiento que hay que conservar

1. `start()` conecta pero **no sube comandos**. `uploadCommands` es explícito y compara con una caché
   para no subir de más.
2. Cada paquete sigue este orden: interceptores de plugins, `RAW` sin esperar, filtros de duplicados de
   member y presence, **mutación de caché**, listeners, y después comandos, componentes o modales. Al
   final se actualiza el estado de ready: `BOT_READY` se emite cuando todos los shards están listos.
3. Middlewares: `next()` sigue, `stop()` sale en silencio, `stop(motivo)` deniega
   (`onMiddlewaresError`) y una excepción va a la ruta de error interno. Los globales corren antes que
   los del comando y los subcomandos heredan los del padre.
4. Una opción requerida siempre trae valor y una opcional puede faltar. Los errores de opciones se
   agregan por opción.
5. La caché respeta los intents y los recursos desactivados.
6. Los shorters hacen REST, luego caché y luego devuelven la estructura.
7. Los plugins se montan en orden y se desmontan en orden inverso, con los fallos envueltos con el
   nombre del plugin.
8. El envío al gateway pasa por wrappers que pueden reemplazar o vetar el payload.

### 1.4 Lo que existe por ser JS/TS y no se porta tal cual

| En Seyfert | Por qué existe | En veyfert |
|---|---|---|
| Workers, `WorkerManager`, proxy de REST entre workers, hot reload por generaciones | JS tiene un solo hilo | Hilos dentro de un proceso; varios procesos solo mediante rangos de shards |
| `locations`, `@AutoLoad`, `reload()`, watcher, `seyfert.config.*` | Carga de código en runtime | Registro explícito, resuelto al compilar; `v watch` en desarrollo |
| `SeyfertRegistry`, `ParseClient`, `declare module` | El tipado solo existe a nivel de tipos | Tipos concretos y genéricos; las dependencias van en campos del comando |
| `Proxy` (router REST, `LangRouter`) | Metaprogramación en runtime | Funciones generadas y structs de idioma |
| Builders con setters encadenados | Ergonomía de JS | Literales de struct con `@[params]` |
| Estructuras camelCase + `Transformers` | Discord usa snake_case y JS usa camelCase | Un solo modelo snake_case |

## 2. Features de V que usa veyfert

| Feature de V | Uso en veyfert | Estado |
|---|---|---|
| Atributos tipados (`@[attribute] struct Declare {...}`) en structs, campos, métodos y funciones, también desde otro módulo (`@[veyfert.Declare(...)]`) | Sustituyen a todos los decoradores | ✅ |
| Reflexión: `$for f in T.fields`, `f.attributes`, `$if a is Schema`, lectura y escritura de `val.$(f.name)`, `$if f.typ is ?int`, `$for v in E.values`, `$for m in T.methods` y `obj.$method()` | Generar el JSON de comandos y modales, volcar las opciones en campos y descubrir hooks opcionales | ✅ |
| Recursión por tipos de campo con genéricos | El árbol comando → grupo → subcomando se declara como tipos | ✅ |
| `$compile_error` dentro de una rama comptime | Una definición inválida da un error de compilación con mensaje propio | ✅ |
| Genéricos con restricciones (`add[T Command]`) | Registros tipados; V obliga a propagar la restricción | ✅ |
| Struct genérico que implementa una interfaz no genérica (`Bound[T]` → `Invoker`) | Borrado de tipos en los registros | ✅ |
| `?T`, `!T`, `or {}` y errores propios con `err is T` | Campos opcionales de Discord, opciones opcionales que hay que manejar, `VeyfertError`/`DiscordError` y el control de flujo de los guards | ✅ `?T` · 📖 errores |
| Enums `@[flag]` con posición de bit y `as u64`, `.has()` y `Enum.from('nombre')` | Intents, permisos (pasan del bit 32) y flags de mensaje | ✅ |
| `json2`: `@[json: 'type']`, `@[raw]`, `decode_standard`, `decode_reuse` + `DecodeBuffer`, `@[json_as_number]`, `@[omitempty]` y hooks `to_json`/`from_json_*` | Decodificación del gateway en dos fases (sobre y `d` crudo), Snowflake como string y `Nullable[T]` para PATCH | ✅ |
| Nombres de campo snake_case obligatorios | Modelos 1:1 con Discord y nombres de opción en minúsculas por construcción | ✅ |
| `net.websocket` (wss, callbacks `!`, escrituras serializadas por conexión, `Server`) | Shards, y un gateway falso para los tests | ✅ cliente · 📖 server |
| `net.http` (`fetch`, cabeceras, reutilización de conexiones, timeouts) | Transporte REST | ✅ |
| `crypto.ed25519` | Verificar firmas de interacciones por HTTP | 📖 |
| `compress.zlib` y `compress.zstd` (contexto de streaming, incluido en `thirdparty`) | Compresión de payload; más adelante `zstd-stream` | 📖 |
| `spawn`, canales, `select` con timeout, `shared`/`lock` y `sync` (RwMutex, WaitGroup, OnceLock) | Shards, pool, `wait_for` y caché compartida | 📖 |
| `ratelimit.TokenBucket`, `log`, `term`, `time`, `semver`, `config.load[T]` | Límite global de REST y cooldowns, logs, colores, requisitos de plugins y configuración desde env, CLI o TOML | 📖 |
| Funciones condicionales `@[if veyfert_trace ?]` | Trazas que desaparecen del binario si no se compila con `-d veyfert_trace` | 📖 |
| `@[params]`, `@[required]`, `@[heap]`, `@[noinit]`, structs embebidos, closures con captura explícita, sobrecarga de operadores | Opciones con nombre, idiomas completos al compilar, cliente compartido entre hilos, constructor obligatorio, campos comunes, handlers y orden de Snowflakes | 📖 |
| `@VMOD_FILE` / `@VMODHASH` | Versión y commit en el `User-Agent` | 📖 |
| `$embed_file`, scripts `.vsh`, `v test` / `-coverage` / `-race`, `v fmt` / `vet` / `doc`, VPM, compilación cruzada (`-os linux`) y `-prod` | Assets dentro del binario, el generador de código, calidad y publicación. Para desplegar en Linux desde Windows hacen falta Clang, LLD y el sysroot que indica V; si no, se compila en CI | 📖 |

**Descartadas, con su motivo:**

| Feature | Motivo |
|---|---|
| `go` (goroutines) | Su README la marca como experimental. `spawn` basta: pocos hilos de larga vida más un pool |
| `@[live]` | La doc dice que no tiene efecto con el compilador por defecto; recomienda `v watch` |
| `x.async`, `x.scheduler`, `x.executor` como base | Los módulos `x.` son experimentales; si se usan, detrás de una API interna pequeña |
| `cache.Lru` | Su README dice que mantener la recencia es lineal y que no es thread-safe |
| `eventbus` | Basado en `voidptr`, sin tipos |
| `i18n` como sistema por defecto | Claves de texto sin comprobar y sin interpolación documentada. Los structs de idioma tipados son más fieles a `ctx.t` |
| ORM/`db`, backends JS y WASM, `-autofree`, `-gc none` | Fuera del alcance, o riesgo sin beneficio |

## 3. Enfoques considerados

| Enfoque | Cómo | A favor | En contra |
|---|---|---|---|
| A. Port literal | Clases → structs, decoradores → atributos de texto, `json2.Any`, mapas en runtime | Se mapea directo desde Seyfert | Desaprovecha los tipos de V; más lento; los errores salen en runtime |
| **B. Comptime-first** (recomendado) | Structs con atributos tipados + reflexión; hilos; un módulo | Errores al compilar, payloads tipados sin `Any`, menos código | Depende de la reflexión de V, que las sondas ya validaron |
| C. Todo generado | Un DSL o una spec → un `.vsh` que genera comandos y modelos | Cobertura mecánica | Mala experiencia para quien escribe el bot. Solo compensa para los modelos REST, y B ya los genera |

**Recomendación: B**, con generación de código solo para los modelos y endpoints REST.

## 4. Diseño

### 4.1 Equivalencias Seyfert → veyfert

| Seyfert | veyfert |
|---|---|
| `@Declare({...})` | `@[veyfert.Declare(name: 'x', description: 'y')]`, más atributos pequeños (`Nsfw`, `Perms`, `Guilds`…), porque un esquema exige todos sus campos |
| `@Options({ q: createStringOption(...) })` | Campos del struct. El tipo del campo decide el tipo de opción, `?T` la vuelve opcional, y `@[Desc]`, `@[Min]`/`@[Max]`, `@[MinLength]`/`@[MaxLength]` y `@[ChannelTypes]` añaden el resto, siempre con un solo valor por atributo (ver riesgo 12). Un campo enum genera las `choices` |
| `ctx.options.q` tipado por inferencia | `c.q`, un campo normal de tipo `string` o `?string` |
| `@Options([SubA, SubB])`, `@Group`, `@Groups` | Campos marcados con `@[Sub]` cuyo tipo es otro comando. Un nivel intermedio se convierte en grupo |
| `createMiddleware` + `@Middlewares(['a'])` + `ctx.metadata.a` | Guards: campos cuyo tipo implementa `Guard` (`check(mut ctx) !`), sin atributo (riesgo 15). El estado que deja el guard es el metadato tipado |
| `stop()` / `stop('motivo')` / excepción | `return veyfert.stop()` / `return veyfert.deny('motivo')` / cualquier otro error |
| Hooks `onRunError`, `onOptionsError`… | Métodos opcionales del struct, descubiertos con `$for m in T.methods`, más defaults en el cliente |
| `createEvent({ data: { name }, run })` | `bot.on[veyfert.MessageCreate](fn (e, mut c) ! {...})`. El nombre del evento sale de `@[Event('MESSAGE_CREATE')]` en el tipo del payload |
| `client.collectors.create(...)` | `c.wait_for[T](filter:, timeout:)`, que bloquea esperando en un canal con `select` |
| `ComponentCommand` / `ModalCommand` | `@[CustomId('x')]` o `@[CustomIdPrefix('x:')]` + `run`. Un modal es un struct cuyos campos son los inputs: la misma reflexión lo genera y lo parsea |
| Builders | Structs planos que reflejan el wire de Discord, más constructores con `@[params]` |
| `client.proxy...` | Una función generada por endpoint, y `rest.request[T](...)` como vía cruda |
| Shorters | `c.messages.write(id, content: '...')!` |
| `SeyfertError` | `VeyfertError{ code, metadata, cause }` y `DiscordError{ status, code, message }` |
| `ctx.t.clave.get()` | `langs.of(ctx).clave`, con `Langs[T]` sobre un struct de idioma cuyos campos son `@[required]` |
| `Logger` | `log.ThreadSafeLog` + `@[if veyfert_trace ?]` |
| `HttpClient` | `veyfert.server.serve(mut bot, port:, public_key:)` |

### 4.2 Lo que escribe el autor de un bot (boceto)

Las piezas están verificadas por las sondas; la API exacta todavía no.

```v
module main

import os
import time
import veyfert

@[veyfert.Declare(name: 'ping', description: 'Responde con la latencia')]
struct Ping {}

fn (c Ping) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(content: 'Pong! ${ctx.client.latency()}')!
}

enum Orden {
	relevancia
	fecha
}

@[veyfert.Declare(name: 'buscar', description: 'Busca en la base de datos')]
struct Buscar {
	db &Db // sin atributo: es una dependencia y viaja con el prototipo
mut:
	cd     veyfert.Cooldown = veyfert.cooldown(3, 10 * time.second) // un guard: corre antes de `run`
	texto  string @[veyfert.Desc: 'Qué buscar']                                          // requerida
	limite ?int   @[veyfert.Desc: 'Máximo de resultados'; veyfert.Min: 1; veyfert.Max: 25] // opcional
	orden  ?Orden @[veyfert.Desc: 'Cómo ordenar']                                      // choices del enum
}

fn (c Buscar) run(mut ctx veyfert.CommandContext) ! {
	hits := c.db.search(c.texto, c.limite or { 10 })!
	ctx.write(
		content: 'Te quedan ${c.cd.remaining} búsquedas'
		embeds:  [veyfert.Embed{ title: 'Resultados', description: hits.join('\n') }]
	)!
}

fn main() {
	db := &Db{}
	mut bot := veyfert.new_client(token: os.getenv('DISCORD_TOKEN'), intents: .guilds)
	bot.commands.add(Ping{})
	bot.commands.add(Buscar{ db: db })
	bot.on[veyfert.Ready](fn (e veyfert.Ready, mut c veyfert.Client) ! {
		c.log.info('Conectado como ${e.user.username}')
	})
	bot.upload_commands(cache_path: '.veyfert/commands.json')!
	bot.run()!
}
```

```v
// Subcomandos: el árbol se declara con tipos
@[veyfert.Declare(name: 'config', description: 'Ajustes del servidor')]
struct Config {
mut:
	idioma Idioma     @[veyfert.Sub]
	mod    Moderacion @[veyfert.Sub] // Moderacion tiene sus propios @[Sub], así que es un grupo
}

// Modal: los campos son los inputs; al enviarlo llega relleno
@[veyfert.Modal(custom_id: 'feedback', title: 'Tu opinión')]
struct Feedback {
mut:
	texto string  @[veyfert.Label: 'Cuéntanos'; veyfert.Paragraph]
	email ?string @[veyfert.Label: 'Email (opcional)']
}

fn (f Feedback) submit(mut ctx veyfert.ModalContext) ! {
	ctx.write(content: 'Gracias', ephemeral: true)!
}

// Dentro de un comando: esperar el siguiente mensaje del mismo usuario
resp := ctx.client.wait_for[veyfert.MessageCreate](
	filter:  fn [uid] (m veyfert.MessageCreate) bool { return m.author.id == uid }
	timeout: 30 * time.second
) or {
	ctx.followup(content: 'Se acabó el tiempo')!
	return
}
```

### 4.3 Comandos por dentro

- `bot.commands.add(proto)` es genérico (`add[T Command]`). Al compilar recorre `T.attributes` y
  `T.fields`, genera el JSON de Discord y guarda un `Bound[T]{ proto }` detrás de una interfaz.
- Al llegar la interacción, copia el prototipo, de modo que las dependencias viajan en la copia. Esas
  dependencias tienen que ser referencias (`&Db`) o valores baratos de copiar. Después rellena las
  opciones y corre los guards globales, los del comando, `run` y los hooks.
- Validación al compilar, con `$compile_error`: tipo de campo no soportado, opción fuera de `mut:` y
  árboles de más de tres niveles. Las longitudes y los límites de Discord se validan al registrar,
  porque V todavía no permite usar los valores de un esquema en un `$if`.
- Autocomplete: un método opcional `autocomplete(mut ctx veyfert.AutocompleteContext) !`. El contexto
  indica qué opción tiene el foco.

### 4.4 Eventos y concurrencia

```
gateway ─► hilo lector (1 por shard) ──canal──► pool de handlers (N hilos) ──► REST
           · decodifica el sobre                · listeners on[T]                (bloqueante,
           · decodifica d solo si hace falta    · comandos, guards y modales      rate limit
           · muta la caché (orden por guild)    · wait_for (puede bloquear)       compartido)
           · resuelve wait_for y colectores
hilo de heartbeat por shard · cola de identify global (max_concurrency, 5 s) · pool aparte para interacciones (3 s)
```

- El lector decodifica el sobre (`op`, `s`, `t` y `d` con `@[raw]`) y solo decodifica `d` si la caché
  o algún listener lo necesitan.
- La caché se muta en el hilo del shard, así que el orden por guild está garantizado mientras no se
  cambie el número de shards.
- Listeners, comandos y componentes pasan al pool por un canal acotado, que aplica contrapresión.
  Las interacciones tienen un pool propio porque Discord da 3 segundos para responder.
- `wait_for` se resuelve en el hilo del shard, así que no ocupa hilos del pool, ni siquiera con un solo
  worker.
- `workers: 1` da semántica secuencial a quien no quiera pensar en concurrencia. Por defecto hay varios
  hilos, y los handlers que comparten estado lo protegen con `shared` o `sync`. Los tests corren con
  `-race` en Linux, porque `-race` no existe en Windows.

### 4.5 Gateway

Es un port directo de `shard.ts`:

- heartbeat con jitter y detección de zombi;
- reanudación con `resume_gateway_url`;
- la tabla de close codes de Seyfert (4004 y 4010–4014 no reconectan);
- cola de envío offline y límite de 120 envíos por 60 s;
- cola de identify por `max_concurrency`, uno cada 5 s;
- `request_guild_members` por nonce con timeout;
- presence, voice state update y compresión de payload con zlib.

El logger de `net.websocket` escribe INFO por defecto (✅), así que se le pasa uno propio.
`max_message_bytes`, que vale 8 MiB por defecto, se expone como opción.

### 4.6 REST

- `request[T](method, path, opts) !T` sobre una interfaz `Transport`: por defecto `net.http`, y un
  mock en los tests.
- El rate limit sigue el de Seyfert. La clave `METODO:ruta` se reasigna al hash de
  `x-ratelimit-bucket` más el parámetro mayor. Hay un límite global por token (`ratelimit.TokenBucket`),
  un 429 espera su `retry_after`, los 502/503 se reintentan tres veces y `/interactions` queda exento
  del global.
- Multipart propio (`payload_json` + `files[n]`), porque `http.post_multipart_form` solo hace POST y
  editar un mensaje con adjuntos es un PATCH.
- `X-Audit-Log-Reason`, `User-Agent: DiscordBot (url, versión)`, helpers de CDN (un hash `a_` es gif;
  tamaños) y observadores.

### 4.7 Modelos y JSON

| Problema | Solución | Estado |
|---|---|---|
| IDs de 64 bits que llegan como string | `struct Snowflake { value u64 }` con `to_json`, `from_json_string` y `from_json_number` públicos; acepta string o número | ✅ |
| Distinguir ausente de `null` en un PATCH | `?Nullable[T]`: `none` se omite y `{is_null: true}` escribe `null` | ✅ |
| Uniones discriminadas por `type` (componentes, canales, interacciones, opciones) | `json2` solo discrimina con `"_type"` y no se puede configurar. Se usan modelos planos como los de Discord (un campo `kind` + opcionales) y vistas tipadas donde haga falta un `match` exhaustivo | ✅ el límite · 🧪 las vistas |
| Gateway | Sobre con `d @[raw]`, `decode_standard[T]` y un `DecodeBuffer` reutilizado por shard | ✅ |
| Bitfields | Enums `@[flag]`; los permisos llegan como string y se convierten desde `u64` | ✅ |

### 4.8 Caché, estructuras y shorters

- Caché en memoria tipada y sin serializar: un mapa por recurso detrás de un `sync.RwMutex`, con los
  mensajes en un anillo por canal. Es sensible a intents, desactivable por recurso y con
  `track_member_count` opcional.
- Adaptadores externos (Redis…) solo cuando alguien los pida: una interfaz sobre JSON serializado y la
  suite de conformidad de Seyfert portada a `v test`.
- Los shorters son cache-first sobre los endpoints generados. Las estructuras que llegan por eventos y
  contextos traen el cliente enlazado en un campo `@[skip]`, rellenado por un recorrido comptime. Eso
  permite `msg.reply(...)` y `member.ban(...)`. 🧪

### 4.9 Componentes, modales y colectores

- Un struct `Component` plano con constructores
  (`veyfert.button(style: .primary, label: 'Sí', custom_id: 'si')`), Components v2 completos y el flag
  `IS_COMPONENTS_V2` (1 << 15).
- `Embed.validate()` comprueba los límites al enviar: título de 256, descripción de 4096, 25 campos y
  6000 caracteres en total.
- Modales como structs: `ctx.modal(Feedback{})!` genera los inputs desde los campos, y al enviar el
  modal `submit` recibe `Feedback` relleno.
- `ctx.wait_for_component(message_id, timeout:, filter:)` sustituye a los colectores.

### 4.10 i18n

`Langs[T]` es genérico: mapea locale → `T`, con alias, fallback y `prefer_guild_locale`. `T` es un struct
del usuario con todos sus campos `@[required]`, así que si un idioma olvida una clave no compila. Las
localizaciones del nombre y la descripción de los comandos salen de esos mismos structs. ✅ Compilan
las constantes con campos de tipo función.

### 4.11 Plugins, errores y logs

- `interface Plugin { name() string; setup(mut c Client) !; teardown(mut c Client) ! }`, con teardown
  en orden inverso. Los plugins usan la API pública del cliente más listas de hooks: observadores de
  REST y de comandos, e interceptores del gateway.
- Requisitos con `semver` y registro `shared` tipado cuando haya un plugin que los necesite, no antes.
- Plugins oficiales: cooldown (un guard sobre `TokenBucket`) y scheduler.

### 4.12 Interacciones por HTTP

El submódulo `veyfert.server` verifica `X-Signature-Ed25519` sobre `timestamp + body` y responde PING
con PONG. Para el resto espera en un canal la primera respuesta del handler y la devuelve en la propia
respuesta HTTP; si no llega en ~2,5 s, contesta con un defer. En Seyfert esta parte está incompleta,
según su propio `client/AGENTS.md`.

### 4.13 Testing

- `veyfert.testing`: un gateway falso sobre `net.websocket.Server`, un transporte mock que registra las
  peticiones, fixtures de payloads y aserciones.
- Tests de no-compilación: un `.vsh` compila casos inválidos y comprueba el mensaje exacto de
  `$compile_error`.
- CI en Linux, macOS y Windows; `-race` solo en Linux.

## 5. Estructura del repositorio

```
veyfert/
├── v.mod  README.md  CHANGELOG.md  LICENSE
├── client.v                 # module veyfert: Client, ClientOptions, interactions, upload
├── gateway.v                # Shard: conexión, heartbeat, resume, close codes, envío con interceptores
├── gateway_manager.v        # shards, cola de identify, presence, voice, members, sesiones guardadas
├── gateway_zstd_*.v         # zstd-stream con -d veyfert_zstd, o un stub sin él
├── dispatch.v               # caché → colectores → pool; on/once/wait_for/emit; duplicados
├── lifecycle.v              # eventos del framework (BOT_READY…) y presence del gateway
├── commands.v  context.v  guards.v  interactions.v  inline.v  prefix.v  langs.v  plugins.v  shorters.v
├── *_test.v                 # tests del framework, junto al código
├── discord/                 # module veyfert.discord: modelos, eventos, componentes, embeds,
│                            #   polls, permisos, intents, snowflakes, CDN, archivos
├── rest/                    # module veyfert.rest: Transport, rate limits, multipart, errores
│   └── api/                 # module veyfert.rest.api: GENERADO, una función por endpoint
├── cache/                   # module veyfert.cache: la caché en memoria
├── plugins/                 # module veyfert.plugins: plugins oficiales (Scheduler)
├── server/                  # module veyfert.server: interacciones por HTTP
├── testing/                 # module veyfert.testing: gateway y REST falsos, payloads
│   └── ws/                  #   servidor WebSocket en 127.0.0.1
├── examples/{basic,components}/
├── tests/compile_fail/      # casos que deben fallar con un mensaje exacto (compile_fail.vsh)
├── tools/gen_api.vsh        # generador desde discord-api-spec (commit fijado)
├── benchmarks/decode/
├── docs/PLAN.md
└── .github/workflows/ci.yml
```

## 6. Fases

| Fase | Objetivo | Criterio de salida |
|---|---|---|
| 0 | Spike vertical | Un bot real responde `/ping` y `/buscar` en un servidor de pruebas, y `v test .` pasa en Windows y Linux |
| 1 | Gateway de producción | Tests contra un gateway falso, sin red: cierres 1006, 4000 y 4004, op 7 y op 9. Un bot real aguanta 24 h con la memoria estable |
| 2 | REST y modelos generados | Tests con transporte mock que reproducen secuencias reales de cabeceras: bucket compartido, 429 global y 502 |
| 3 | Comandos | Tests de despacho con interacciones de ejemplo, tests de no-compilación y checklist de paridad con la guía de comandos de Seyfert |
| 4 | Componentes, modales y mensajes | El JSON generado coincide con los ejemplos de la doc de Discord; prueba manual con el bot |
| 5 | Caché, estructuras y shorters | Tests de consistencia con secuencias de eventos y `-race` limpio en Linux |
| 6 | Prefijo, i18n, plugins y HTTP | Test HTTP con peticiones firmadas con una clave generada en el propio test |
| 7 | Producción y publicación | `veyfert.testing` público, docs, ejemplos y benchmarks; CI en los tres sistemas y publicado en VPM |

Las fases 3 a 6 pueden solaparse una vez terminadas la 0, la 1 y la 2, que son las que construyen gateway
y REST.

**Fase 0 — Spike vertical.** Demuestra el camino completo antes de invertir en amplitud.
- **Estado (23-11-2026): hecha en Windows.** El bot de `examples/basic` subió `/ping` y `/buscar` a un
  servidor de pruebas, identificó en el gateway, mantuvo el heartbeat y respondió los dos comandos
  desde Discord. `v test .` pasa. Falta pasarlo en Linux (CI). La prueba destapó dos cosas: el logger
  de `log` no vacía su búfer por línea si no se le pide (`set_always_flush(true)`), y el riesgo 12.
- `v.mod`, `.gitignore` (con `.env` y `.veyfert/`) y CI mínimo.
- `Snowflake`, `Nullable[T]`, `Intents` y `Permissions`; las sondas de esta sesión pasan a `_test.v`.
- Un shard: HELLO → IDENTIFY → heartbeat → READY, con el sobre y `d @[raw]`.
- REST mínimo: callback de interacción, `create_message`, `User-Agent` y `DiscordError`.
- Registro por atributos (`Declare`, `Desc`, `Min`, `Max`) y `upload_commands` a un servidor de pruebas.
- Requisitos: una aplicación de Discord de pruebas, su token en `DISCORD_TOKEN` (nunca en el repo) y un
  servidor de pruebas.

**Fase 1 — Gateway de producción.**
- **Estado (24-11-2026): hecha en Windows, salvo la prueba de 24 h.** Hay 12 escenarios contra un
  gateway falso, sin red: 1006, 4000, 4004, 4009, op 7, op 9 reanudable y no reanudable, zombi, cola
  offline, chunks de miembros, carga de guilds y payloads con zlib. También hay 6 tests de despacho.
  Todos pasan, estables en dos pasadas.
- Contra Discord real: el bot arrancó con presence y `BOT_READY`, `request_members` por ID devolvió
  el miembro y `reconnect(0)` reanudó la sesión. `stop()` cierra limpio. Desde Discord, `/yo` y
  `/reconectar` respondieron, la sesión se reanudó en 0,4 s y `/ping` siguió respondiendo después.
  Estuvo 30 minutos en línea sin desconexiones no provocadas.
- Benchmark (`benchmarks/decode`, `-prod`): READY de 2500 guilds en 1,7 ms; GUILD_CREATE de 1000
  miembros (281 KiB) en 3,6 ms; MESSAGE_CREATE en 4 µs. Son unos 70 MiB/s con `json2`.
- Los filtros de duplicados de member y presence se hicieron en la fase 5, y `max_message_bytes`
  es una opción del cliente desde la fase 7. Falta pasarlo en Linux y con `-race` (CI).
- Resume y reconexión con la tabla de close codes de `shard.ts`, detección de zombi, timeout de conexión
  y cola de envío offline.
- Varios shards en un proceso, con cola de identify por `max_concurrency`, rango de shards (`start`,
  `end`, `total`), presence por shard y el límite de 120 envíos por 60 s.
- `request_guild_members` (nonce, chunks, timeout), voice state update y compresión de payload con zlib.
- Despacho: `on[T]`, `once[T]`, `RAW`, `emit[T]` para eventos propios, `GUILDS_READY`, `BOT_READY` y
  `SHARD_DISCONNECT`/`SHARD_RECONNECT`. Decodificación perezosa y filtros de duplicados de member y
  presence.
- Benchmark de decodificación: READY, un GUILD_CREATE grande y MESSAGE_CREATE.

**Fase 2 — REST y modelos generados.**
- **Estado (24-11-2026): hecha en Windows.** `rest.v` tiene un `Transport` intercambiable, buckets
  aprendidos (un bucket compartido recibe las cabeceras de todas sus rutas), un límite global de
  50/s con bloqueo ante un 429 global (las interacciones quedan exentas), reintentos de 502/503,
  multipart propio, `X-Audit-Log-Reason`, observadores y CDN. Hay 10 tests con transporte simulado.
- `tools/gen_api.vsh` lee la spec fijada (`3a21a01`) y genera 447 structs, 68 enums enteros y 247
  de 250 endpoints. Omite los 3 que solo aceptan cuerpo multipart y 18 parámetros de query que son
  arrays. Contra Discord real decodificó usuario, aplicación, servidor y mensajes.
- Decisiones: los campos enum son `int`/`string`, porque Discord añade valores y `json2` rechaza los
  desconocidos; los enums se generan aparte para comparar. Lo que la spec modela como unión
  (canales, componentes) llega como `RawJson`; las vistas tipadas son de la fase 5.
- Hecho en la fase 7: en los cuerpos de PATCH, los 84 campos que admiten `null` se generan como
  `?Nullable[T]` (`none` lo deja igual, `{is_null: true}` lo borra). Los enums de texto siguen
  sin generarse.
- `tools/gen_api.vsh` sobre discord-api-spec en un commit fijado: modelos y una función por endpoint,
  con overrides a mano donde la spec falle.
- Rate limiter completo (ver 4.6), multipart propio, `X-Audit-Log-Reason`, `request[T]`, CDN y
  observadores.

**Fase 3 — Comandos.**
- **Estado (24-11-2026): hecha en Windows.** `commands.v` registra árboles de tipos (`@[Sub]`, con
  grupos un nivel por debajo del comando), menús de usuario y de mensaje, y opciones de los 13
  tipos de campo con `Min`/`Max`, `MinLength`/`MaxLength`, `Channels`, `Autocomplete` y `Label`
  en los valores de enum. Los guards son campos cuyo tipo implementa `Guard` (sin `@[Use]`, ver
  riesgo 15). Corren en este orden: permisos del bot, opciones, globales, los de los grupos y los
  del comando. Hay `stop`/`deny`, `Cooldown` y `RequirePermissions`, hooks por método
  (`on_run_error`, `on_options_error`, `on_guard_error`, `on_bot_permissions_fail`) y
  `CommandDefaults` en el cliente. También `Perms`, `BotPerms`, `Nsfw`, `Guilds`, `Contexts` e
  `Integrations`, y upload por ámbito (global y por servidor).
- 15 tests de despacho con interacciones de ejemplo y 3 de no-compilación
  (`v run tests/compile_fail.vsh`). Contra Discord real, el servidor aceptó los 8 comandos del
  ejemplo: el árbol `/config`, los dos menús, autocomplete, tipos de canal y longitudes.
- Tiempo de compilación: un bot de 100 comandos (cada uno con cooldown, un enum, un `User` y dos
  opciones más) compila en 12,2 s, frente a 5,7 s con uno; son unos 65 ms por comando, y el
  binario pasa de 3,4 a 4,1 MB.
- Quedan para otras fases: `modal` en los contextos (fase 4), `guild()`/`channel()` desde la
  caché (fase 5) y los comandos entry point.
- El tipo del campo decide el tipo de opción: `string`, `int`, `f64`, `bool`, `User`, `Member`, `Role`,
  `Channel`, `Mentionable` o `Attachment`. `?T` la vuelve opcional y un enum genera las choices, con
  nombres localizables mediante atributos en los valores. Además `Min`/`Max`, `MinLength`/`MaxLength` y
  `ChannelTypes`.
- Autocomplete, subcomandos y grupos como árbol de tipos, y menús contextuales de usuario y de mensaje.
  Los comandos entry point quedan para el final.
- Contextos con `write`, `defer_reply`, `edit_response`, `delete_response`, `followup`, `fetch_response`,
  `edit_or_reply`, `modal` y ephemeral, más `author`, `member`, `guild` y `channel`.
- Guards por campo y globales, hooks opcionales y defaults del cliente. Permisos
  (`default_member_permissions`, y permisos del bot con `on_bot_permissions_fail`), `integration_types`,
  `contexts`, `nsfw`, comandos por guild y upload con caché por hash.
- Las validaciones de 4.3. Medir el tiempo de compilación con 100 comandos sintéticos.

**Fase 4 — Componentes, modales y mensajes.**
- **Estado (24-11-2026): hecha en Windows, salvo la prueba manual de modales.** `components.v` tiene
  un `Component` plano con constructores para los 20 tipos: los de v1, los de Components v2 y los
  de modal (`label`, `file_upload`, `radio_group`, `checkbox_group`, `checkbox`). El hijo único de
  `section` y `label` va ya codificado, porque V no admite structs que se contengan a sí mismos.
  `IS_COMPONENTS_V2` se pone solo cuando hay componentes v2. También están `Embed` completo con
  `validate()`, que se comprueba al enviar, polls, `allowed_mentions`, `tts`, flags y adjuntos
  (`file_from_path`, `file_from_url`).
- `interactions.v` enruta los handlers por `CustomId` exacto o por el `CustomIdPrefix` más largo.
  `ComponentContext` tiene `update` y `defer_update`. Los modales son structs (`@[Modal]`, con
  campos `@[Label]` de tipo string, ?string o enum, que se convierte en select): `ctx.modal(form)`
  los genera rellenando los valores y el envío llega al struct relleno, tanto en el formato con
  labels como en el antiguo con action rows. `wait_for_component` y `wait_for_modal` se quedan con
  la interacción, que ya no llega a los handlers.
- 9 tests y uno de adjuntos. Contra Discord real se publicaron y borraron tres mensajes: uno v1
  con embed completo, botones y selects; uno v2 con contenedor, sección con miniatura, separador,
  galería y archivo adjunto por multipart; y una encuesta. Los modales necesitan que alguien los
  abra en Discord: `examples/components` los trae.
- Adelantado de la fase 5: `c.messages` con `write`, `edit`, `delete` y `fetch`.
- `Component` plano con constructores, Components v2 completos e `IS_COMPONENTS_V2`. `Embed.validate()`,
  polls, adjuntos (bytes, ruta o URL) y `allowed_mentions`.
- Handlers por `custom_id` exacto o por prefijo, modales como structs, `wait_for_component`,
  `wait_for_modal`, `update` y `defer_update`.

**Fase 5 — Caché, estructuras y shorters.**
- **Estado (24-11-2026): hecha en Windows, salvo `-race` (solo Linux).** `cache.v` guarda guilds,
  canales e hilos (con sus overwrites), roles, usuarios, miembros, emojis, stickers, presences,
  voice states, stage instances, bans y los últimos N mensajes por canal. Hay un mapa por
  recurso, cada uno desactivable, detrás de un `RwMutex`, y se actualiza en el hilo del shard
  antes que los listeners. `events.v` tipa 30 eventos más. Los `GUILD_MEMBER_UPDATE` y
  `PRESENCE_UPDATE` repetidos en 1,5 s solo llegan a los listeners RAW, como en Seyfert.
- `shorters.v`: messages, reactions, channels, members, roles, guilds, users, threads, webhooks,
  bans y emojis (unos 50 métodos). Los `fetch`/`list` leen primero la caché (`force: true` va a
  Discord) y el motivo de auditoría va en el struct de opciones. `RawJson.decode[T]()` convierte
  lo que devuelve un endpoint generado en un modelo propio.
- Decisión: nada de cliente dentro de las estructuras, ni en un campo `@[skip]` relleno por
  reflexión, porque dejaría punteros nil en los structs creados a mano. Primero las estructuras
  recibían el cliente (`msg.reply(mut c, ...)`). Desde la división en capas (fase 7), los tipos
  viven en `veyfert.discord`, y V no permite métodos fuera del módulo del tipo. Por eso esas
  acciones están en los shorters (`c.messages.reply(msg, ...)`, `c.members.ban(...)`).
- 9 tests (consistencia de la caché con secuencias de eventos, duplicados y shorters con
  transporte simulado). Contra Discord real, la caché se llenó con `GUILD_CREATE`; además
  funcionaron enviar, responder citando, reaccionar, fijar, desfijar, editar, listar reacciones
  y borrar en bloque, y los eventos de mensaje actualizaron la caché.
- La caché en memoria de los 13 recursos (ver 4.8).
- Shorters por prioridad: messages, interactions, channels, members, roles, guilds, threads, reactions,
  webhooks, bans, emojis y users. Después el resto, hasta cubrir los ~160 métodos de Seyfert.
- Métodos en las estructuras con el cliente enlazado.

**Fase 6 — Prefijo, i18n, plugins e interacciones por HTTP.**
- **Estado (24-11-2026): hecha en Windows.**
  - **Prefijo (`prefix.v`):** los mismos tipos de comando corren desde mensajes, con
    `ClientOptions.prefixes`, un `Commands.prefix` dinámico o la mención al bot. También hay alias
    (`@[Aliases]`) e `@[Ignore('slash'|'prefix')]`. Las opciones van en orden o como `-nombre
    valor`, y la última de texto toma el resto de la línea. Las choices se aceptan por valor o
    etiqueta, las menciones e IDs se resuelven como en una interacción (caché primero) y los
    adjuntos van en orden. Las respuestas son mensajes del canal: `write` responde citando,
    `defer_reply` muestra "escribiendo" y `edit_response` edita. Los guards ven permisos
    calculados desde la caché (`Cache.permissions`: roles, owner y overwrites, también de
    hilos).
  - **i18n:** `Langs[T]` con alias, idioma base, fallback y `prefer_guild_locale`. `Commands.localize`
    toma nombres, descripciones y choices de campos `CommandText` (`@[Locale]`). Compilan las
    constantes con campos función.
  - **Plugins:** `Plugin` con `install` y teardown en orden inverso al acabar `run`,
    `Commands.observe` (`CommandEvent` con el resultado) y `Client.intercept` para cambiar o
    descartar eventos. `Scheduler` es el plugin oficial; el cooldown ya era un guard.
  - **`veyfert.server`:** verifica la firma Ed25519, responde PING y devuelve en la respuesta HTTP la
    primera respuesta del handler. A los 2,5 s manda un defer (6 en componentes) y la respuesta
    tardía edita el defer. Es un servidor HTTP/1.1 propio (riesgo 17).
- 16 tests nuevos, entre ellos el de HTTP con peticiones firmadas con una clave generada en el test. No
  probado contra Discord: el prefijo necesita que alguien escriba (`examples/basic` ya lo
  activa) y el endpoint HTTP, una URL HTTPS registrada en el portal.
- Comandos por prefijo con las mismas definiciones: alias, parser de argumentos, errores por opción y
  la opción de ignorar el modo slash o el de mensaje.
- `Langs[T]` y localizaciones de comandos.
- Plugins (ver 4.11), con cooldown y scheduler como oficiales.
- `veyfert.server` (ver 4.12).

**Fase 7 — Producción y publicación.**
- **Estado (24-11-2026): hecha, salvo lo que no depende de esta sesión.**
  - `veyfert.testing` es público: un gateway falso en 127.0.0.1, `Transport` que graba
    peticiones y responde por turnos, `client(gw, api)` y payloads (`command_interaction`,
    `component_interaction`, `modal_submit`, `message_create`).
  - Documentación: `README.md` es la guía, con la estructura de la de Seyfert, y sus fragmentos
    se compilan. `v doc` genera la referencia, y quedan los dos ejemplos.
  - Hay `CHANGELOG.md`, `LICENSE` y CI en `.github/workflows/ci.yml` (Linux, macOS y Windows):
    formato, tests, zstd, no-compilación y ejemplos con `-W`, más `-race` en Linux y macOS.
    La política de deprecación está en el README.
  - Opcionales hechos: guardar la sesión al parar y reanudarla al arrancar (`save_sessions`,
    `load_sessions`; la caché empieza vacía y `BOT_READY` se emite igual) y `zstd-stream`
    (`zstd: true`, compilando con `-d veyfert_zstd`, así que no cuesta nada a quien no lo usa).
  - Reorganización en capas: el núcleo `veyfert` sobre `veyfert.discord`, `veyfert.rest` (con
    `veyfert.rest.api`) y `veyfert.cache`, más `veyfert.plugins`; ver §0 y §5. Lo hizo un script
    que cualifica los nombres movidos sin tocar strings ni comentarios.
  - Se cumplen los dos contratos de §1.3 que faltaban:
    - (6) cada shorter guarda en la caché lo que devuelve el REST, y lo que borra lo olvida;
      un mensaje enviado no se duplica cuando llega su `MESSAGE_CREATE`.
    - (8) `intercept_send` cambia o descarta cualquier payload que envía un shard.
  - Fuera de la sesión: publicar en VPM (necesita la cuenta y el OK del dueño), la prueba de
    24 h, ejecutar el CI (no hay repositorio remoto), los benchmarks contra Seyfert y el
    resharding automático. Ese último lo dejé: reiniciar los shards con otro total en caliente
    pide reestructurar `run`, y el rango manual (`ShardRange`) cubre los bots grandes de hoy.
- `veyfert.testing` público.
- Opcionales: `zstd-stream`, resharding automático y guardar la sesión al parar para reanudarla al
  arrancar, avisando de que la caché empieza vacía.
- Documentación (`v doc` y una guía con la misma estructura que la de Seyfert), ejemplos y benchmarks
  contra Seyfert (RAM por guild y eventos por segundo).
- CI en Linux, macOS y Windows, publicación en VPM y política de deprecación con `@[deprecated]` y
  `@[deprecated_after]`.

## 7. Riesgos y huecos de V encontrados

| # | Hallazgo | Evidencia | Mitigación en veyfert | Posible PR a V |
|---|---|---|---|---|
| 1 | `json2` solo discrimina sum types con `"_type"`, sin opción para cambiarlo | Al codificar añade `"_type":"Button"`. Al decodificar JSON de Discord: `could not resolve sumtype ... missing "_type" field?` | Modelos planos. Si una variante tiene su propio `to_json`, `json2` lo usa y no escribe `_type`. Para decodificar, `from_json(Any)` + `decode_any[T]` | Un atributo para elegir la clave y el valor del discriminante |
| 2 | Un campo `?SumType` (`Null \| string`) no compila | `unknown function val.to_json` | `?Nullable[T]` | Hoy compila, pero `json2.Null` dentro de un sum type sale como `{"_type":"Null"}` en vez de `null`: [vlang/v#32880](https://github.com/vlang/v/issues/32880) |
| 3 | Un esquema de atributo exige todos sus campos y no admite valores por defecto ni repetirse en la misma declaración | `attribute X is missing field`, `cannot have a default value`, `duplicate attribute` | Esquemas pequeños y listas separadas por comas (`@[Use('a,b')]`) | Campos opcionales con valor por defecto |
| 4 | Los valores de un esquema no se pueden usar en un `$if` | La doc de atributos dice que "requires further work" | Validar longitudes y nombres al registrar, no al compilar | Exponer esos valores al comptime |
| 5 | `-race` no existe en Windows | Doc de V | CI en Linux, o WSL en local | — |
| 6 | El logger de `net.websocket` escribe INFO, y cada mensaje tiene un tope de 8 MiB | Salida de la sonda; README del módulo | Logger propio y el tope como opción | — |
| 7 | `post_multipart_form` solo hace POST | Código de `net.http` | Multipart propio sobre `fetch` | Aceptar el método como parámetro |
| 8 | La spec OpenAPI de Discord está en "public preview" y no cubre el gateway | README de discord-api-spec | Commit fijado, overrides y gateway a mano | — |
| 9 | Los módulos `x.` son experimentales | Convención de vlib | Una API interna fina por encima | — |
| 10 | El tiempo de compilación crece con cada comando, porque cada tipo instancia los genéricos | El REST generado añade 1,3 s a cada build (5,5 s frente a 4,2 s del ejemplo) aunque el bot no use sus endpoints; el binario apenas cambia | Medido en la fase 3: 100 comandos compilan en 12,2 s frente a 5,7 s con uno (unos 65 ms por comando). En la fase 7 el REST generado pasó a `veyfert.rest.api`: `examples/basic` compila en 8,7-9,2 s frente a 10,4-11,5 s con él dentro del núcleo | — |
| 11 | El rendimiento de `json2` en payloads grandes del gateway | Sin medir | Benchmark en la fase 1; si falla, usar el scanner de tokens de `json2` en los eventos calientes | — |
| 12 | `v fmt -w` aplana los atributos de campo con varios argumentos: `@[Range(min: 1, max: 10)]` pasa a `@[Range; Range_min: 1; Range_max: 10]`. Compila con avisos, pero con `-prod` o `-W` falla | `unknown attribute Range_min ... Unvalidated attributes are deprecated` en la fase 0 | En los campos, solo esquemas de un valor (`Min`, `Max`, `Desc`, `Label`); `v fmt` los deja en la forma equivalente `@[Min: 1]`. Los atributos de struct con varios argumentos no se tocan | [vlang/v#32875](https://github.com/vlang/v/issues/32875) |
| 13 | `net.websocket` llama a `on_close` dos veces cuando el servidor cierra (con su código y luego con 1000), y reporta una conexión rota como 1000 tras un error de lectura | Código de `websocket_client.v` (líneas 178-183 y 235-237); en la fase 1 todo cierre del servidor acababa en "sesión nueva" | El shard se queda con el primer reporte de cada conexión y trata como 1006 un cierre precedido de `on_error` | [vlang/v#32878](https://github.com/vlang/v/issues/32878) |
| 14 | Un `select` dentro de una librería no enlaza con `-skip-unused`, la opción por defecto: el C llama a `sync__channel_select_lang` sin declararla | El ejemplo de la fase 1 solo compilaba con `-no-skip-unused`; los tests sí porque su propio código usa `select` | `recv_until` sondea con `try_pop` cada 10 ms; volver a `select` cuando V lo arregle | No se reprodujo aislado en V 0.5.2 `0a43261` (un `select` en un módulo, genérico o no, compila); sin issue mientras no haya caso mínimo |
| 15 | Una llamada genérica dentro de `$if a is Schema` (o `$if a.name == '...'`) se instancia para el tipo de todos los campos del struct, no solo de los que llevan el atributo. `$compile_error` sí respeta la rama | Sonda de la fase 3: `guard_fn(proto.$(field.name))` bajo `$if a is Use` pidió `int.check` y `string.check` | Filtrar por tipo, que sí acota la instancia: los guards se detectan con `$if field.typ is Guard`, y la recursión de `@[Sub]` va dentro de `$if field.typ is $struct` | [vlang/v#32876](https://github.com/vlang/v/issues/32876); además `v -check` no ve un `$compile_error` en esas ramas: [vlang/v#32877](https://github.com/vlang/v/issues/32877) |
| 16 | Con `-skip-unused` (la opción por defecto), una instancia de un método genérico a la que solo llama la propia librería no se genera: el C llama a `veyfert__Client_Interaction__wait_for` sin definirla. Desde el código del bot, la misma llamada funciona, y los tests no lo detectan | Build de `examples/components` en la fase 4; `@[markused]` no lo arregla, y `-no-skip-unused` choca con otro bug de vlib (`http.DebugHandler`) | La librería no llama a sus genéricos de eventos: `wait_interaction` es una espera concreta. Cada ejemplo se compila con `-W` como test de humo | No se reprodujo aislado (un caso con la misma estructura compila). Se parece a [vlang/v#27205](https://github.com/vlang/v/issues/27205), cerrado. En el C, la expresión toma el nombre o el tipo de otro nodo, igual que en el riesgo 17; sin issue mientras no haya caso mínimo |
| 17 | `net.http.Server` no compila con veyfert en el build: en el C de `http.DebugHandler`, `time.now()` sale como `i64` (`cannot convert struct time__Time to long long`). Un programa mínimo con `http.Server` sí compila, y el `time.now()` de vlib cae en el mismo byte que un `$if field.typ is ?i64` de `commands.v`, lo que apunta a un tipo cacheado por posición | Test de `veyfert.server` (fase 6) y `-no-skip-unused` (fase 4); C generado de los dos builds | Servidor HTTP/1.1 mínimo sobre `net` (un hilo por petición, sin keep-alive), suficiente para los POST de Discord | Sin issue: no se pudo aislar. Alinear a mano las posiciones en dos archivos no lo reprodujo |
| 18 | El servidor de `net.websocket` siempre escucha en todas las interfaces (`:port`), sin opción de dirección. En Windows, cada ejecutable de test nuevo que abre un puerto así dispara el aviso del firewall, y el usuario lo vio "a cada rato" | `websocket_server.v`, línea 80 | `veyfert.testing.ws`: un servidor de websocket mínimo en 127.0.0.1 para los gateways falsos, y `veyfert.server` con opción `host` | Aceptar la dirección en `new_server` |
| 19 | `json2` decodifica un campo `@[raw]` como el texto JSON, pero al codificar lo escribe entre comillas: decodificar y volver a codificar cambia el documento | Sonda de la fase 2 | `RawJson`, con `from_json(Any)` y `to_json()` propios | [vlang/v#32879](https://github.com/vlang/v/issues/32879) |
| 20 | El `zero()` que V genera para un enum `@[flag]` no se encuentra con prefijo de módulo: `discord.Permissions.zero()` da `unknown function: Permissions.zero`. Los métodos estáticos propios (`discord.Permissions.parse`) sí funcionan | Reorganización en capas (fase 7) | `discord.no_permissions()` | Pendiente de reportar |

## 8. Decisiones tomadas por defecto

- Nombre y módulo `veyfert`, como la carpeta, con licencia MIT como Seyfert.
- La API, sus identificadores y su documentación en inglés; este plan en español.
- Varios hilos por defecto, con `workers: 1` como opción.
- Sin `WorkerManager`: para usar varios procesos, rangos de shards.
- Sin adaptadores de caché externos ni sistema de plugins completo hasta que haya un caso real que los
  pida.
- Voz: solo el gateway (unirse y salir); el audio queda fuera.
- Sin plazos: cada fase termina cuando pasa su criterio de salida.

## 9. Contexto: otras librerías de Discord en V

| Repositorio | Estado (API de GitHub, 23-11-2026) |
|---|---|
| [DarpHome/discord.v](https://github.com/DarpHome/discord.v) | Activa: último push el 15-06-2026, 42★. "Discord API implementation library" |
| [Terisback/discord.v](https://github.com/Terisback/discord.v) | Archivada, 115★. Es la única que se presenta como framework |
| [CesiumLabs/vcord](https://github.com/CesiumLabs/vcord) | Archivada, WIP |
| [vlang/viscord](https://github.com/vlang/viscord) | Sin cambios desde 2020 |

No revisé su código. Conviene leer DarpHome/discord.v antes de la fase 0 para comparar cómo resuelve
gateway y REST.

## 10. Fuentes

- Seyfert: <https://github.com/tiramisulabs/seyfert> (commit `ac6e8e9`, incluidos sus `AGENTS.md` por
  subsistema).
- Spec OpenAPI de Discord: <https://github.com/discord/discord-api-spec> (`specs/openapi.json`, último
  push el 06-11-2026).
- Documentación de V instalada: `C:\v\doc\docs.md`, `C:\v\doc\custom_attributes.md`,
  `C:\v\doc\custom_attribute_arguments.md`, `C:\v\vlib\json2\README.md`,
  `C:\v\vlib\net\websocket\README.md`, y los README de `goroutines`, `cache`, `ratelimit`, `i18n`,
  `x\async`, `x\executor` y `compress\*`.
- Búsqueda de librerías existentes: <https://vpm.vlang.io/packages/Terisback.discordv>,
  <https://awesome.ecosyste.ms/projects/github.com%2Fvlang%2Fviscord>,
  <https://www.github.com/CesiumLabs/vcord>.
