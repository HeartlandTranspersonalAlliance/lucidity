# Native configuration source audit

This audit evaluates whether configuration and script payloads currently embedded
in Nix should instead live in their native source formats. The goal is easier
review, editor support, focused linting, and clearer ownership without weakening
Nix evaluation, reproducibility, or role-specific composition.

## Current inventory

The repository has no `builtins.toFile` uses and five direct `pkgs.writeText`
call sites:

| Site | Output | Decision |
| --- | --- | --- |
| `nix/flake/project.nix` | production OpenTofu variables JSON | Keep generated with `builtins.toJSON`; the Nix attribute set is the typed source of truth. |
| `nix/flake/project.nix` | evaluated host manifest JSON | Keep generated; values come from the evaluated Den host graph. |
| `nix/flake/architecture.nix` | Mermaid architecture graph | Keep generated; reflecting the evaluated graph is the purpose of the output. |
| `nix/den/classes/bootc/image.nix` | 43 bootc root filesystem entries | Migrate suitable payloads to native source files; keep Nix responsible for selection, substitution, permissions, and installation. |
| `nix/den/classes/bootc/image.nix` | role-specific Containerfile | Migrate to a checked-in `Containerfile.in` template with explicit substitutions. |

The 43-entry bootc map is the main opportunity. Five entries already use the
preferred source-backed pattern through `builtins.readFile`: the common backup
script, the Nix smoke flake and lock file, and the controller and worker
bootstrap scripts. The remaining map combines configuration, systemd units,
shell scripts, evaluated store paths, and very small generated values in one
746-line Nix module.

`pkgs.writeShellApplication` and `pkgs.writeShellScriptBin` uses are not part of
this migration by default. They create executable derivations, wrappers, or test
doubles rather than materializing application configuration. Long application
bodies should still be source-backed, as `nix/pkgs/lucidity.nix` already does
for repository scripts.

## Decision rules

Use a native source file when:

- the payload has its own established syntax, linter, or editor support
- most of the payload is static and Nix substitutes only a few explicit values
- reviewers benefit from seeing the file without Nix string escaping
- the same source can be tested directly before it enters the Nix store

Keep generation in Nix when:

- the content is a serialization of typed or evaluated Nix data
- role selection changes structure rather than a small set of placeholders
- the generated artifact exists specifically to describe the evaluated graph
- moving it would duplicate infrastructure or policy state in a second language

For templates, prefer the pinned nixpkgs `pkgs.replaceVars` helper for explicit
`@name@` placeholders. Use `pkgs.substituteAll` only when its broader substitution
behavior is required. Plain static files should enter the store as paths without
an intermediate `writeText`. Nix must continue to own destination paths, modes,
role selection, and closure references.

## Recommended migrations

### 1. Containerfile template

Move the embedded Containerfile to
`nix/den/classes/bootc/files/Containerfile.in`. Substitute only the role and the
space-separated role-specific unit list. Container build arguments such as
`${BASE_IMAGE}` and `${IMAGE_VERSION}` then remain ordinary Containerfile syntax
instead of escaped Nix interpolation.

This is the smallest high-value conversion. The current template is mostly
static, has only two Nix-owned values, and becomes directly discoverable by
Containerfile-aware tooling.

### 2. Static operating-system configuration

Move static SSH, sysusers, tmpfiles, systemd service, and timer payloads beneath
`nix/den/classes/bootc/files/common`, `controller`, and `worker`. Split the
role-specific sysusers and tmpfiles lines into role fragments instead of keeping
conditional text inside a single Nix string.

Good first candidates include the Determinate Nix installer service, admin-key
service, Nebula expiry service and timer, backup timer, storage services,
workload-token service, and OpenBao snapshot service and timer. The Nix module
should select the common and role maps and install their paths unchanged.

### 3. Runtime script templates

Move the remaining embedded shell programs to native `.sh` or `.sh.in` files.
Static scripts can use `builtins.readFile`. Scripts that require store paths or
evaluated values should use explicit placeholders for packages, profile paths,
fingerprints, or helper binaries and be materialized with `pkgs.replaceVars`.

This gives ShellCheck direct source files, removes doubled interpolation escapes,
and follows the existing backup and bootstrap script pattern. The migration must
retain the current policy that copied executables receive Nix-store-resolved
interpreters before testing.

### 4. Templated systemd units and examples

Move units with a small number of substitutions to `.service.in` files. The
backup service, Nebula service, controller bootstrap service, AWS workload
credentials provider service, and OpenBao service need explicit package or
profile paths. Keep those values visible in the Nix call site rather than using
an unbounded replacement environment.

The controller runtime-secret reference example can be a native `.env.example`
file because its dynamic references are static public configuration. The backup
target example should remain a template because the role is evaluated.

## Keep generated

Do not convert these areas to checked-in rendered files:

- `nix/infra/aws.nix` and `nix/infra/state.nix`: Terranix attribute sets are the
  composable infrastructure source. The 613-line AWS module should be split by
  infrastructure concern if readability becomes a problem, not replaced with a
  generated `.tf.json` snapshot.
- `nix/den/classes/bootc/nebula.nix` and the mesh test YAML: role-dependent
  structured generation prevents controller and worker policy drift.
- cloud-init fixture JSON: runtime keys, fingerprints, registry endpoints, and
  role selection are intentionally serialized at execution time.
- Docker daemon JSON, production variables JSON, and host manifests: typed JSON
  generation provides deterministic escaping and schema-shaped review.
- architecture Mermaid output: it must track the evaluated Den namespace.
- test-only `writeShellScriptBin` stubs: their derivation identity and injected
  behavior are the test mechanism.

## Proposed implementation sequence

1. Extract the Containerfile and purely static common/role configuration. Assert
   byte-for-byte equality of both bootc contexts before and after the move.
2. Extract embedded shell scripts with explicit `pkgs.replaceVars` inputs. Run
   ShellCheck directly on every new source file plus the existing runtime tests.
3. Extract templated systemd units and role fragments. Validate them with
   `systemd-analyze verify` in a Nix check and rerun controller and worker VM
   lifecycle tests.
4. Split `image.nix` into file assembly, common payload selection, and role
   payload selection only after the sources are externalized. Avoid changing
   behavior and module structure in the same review step.

Each implementation PR should preserve generated path names, modes, rendered
bytes, enabled units, and closure references. Roll back an individual extraction
by restoring that payload to the generated map; no compatibility shim is needed
at this stage of development.

## Conclusion

Native files are feasible and worthwhile for the bootc Containerfile, embedded
runtime scripts, systemd units, and static operating-system configuration. They
are not an improvement for typed JSON, evaluated manifests, Terranix resources,
role-structured YAML, or graph outputs. The recommended boundary keeps Nix as
the composition and installation layer while making domain-specific payloads
ordinary, directly lintable source files.
