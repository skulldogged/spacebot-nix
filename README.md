# spacebot-nix

Standalone Nix packaging for `spacebot`.

This repo tracks the upstream source as a flake input:

- `spacebot-src = { url = "github:spacedriveapp/spacebot"; flake = false; }`

That keeps Nix hash churn isolated here instead of in the main application repo.

## Common commands

Build upstream Spacebot:

```bash
nix build .#spacebot
```

Build against a local checkout while working on packaging:

```bash
nix build .#spacebot --override-input spacebot-src path:../spacebot
```

Enter the default dev shell:

```bash
nix develop
```

Update the upstream source revision in `flake.lock`:

```bash
nix flake lock --update-input spacebot-src
```

Or let the repo update both the upstream revision and `frontendNodeModulesHash` for you:

```bash
./scripts/update-spacebot.sh
```

Update packaging inputs like `nixpkgs` or `crane`:

```bash
nix flake lock --update-input nixpkgs --update-input crane --update-input flake-utils
```

`./scripts/update-spacebot.sh` rewrites `nix/default.nix` with `lib.fakeHash`, builds `.#frontend` once to capture the expected hash from Nix, and writes the reported `frontendNodeModulesHash` back into `nix/default.nix`.

## Automation

GitHub Actions runs `.github/workflows/update-spacebot.yml` once per day and on manual dispatch. The workflow runs `./scripts/update-spacebot.sh` and commits the refreshed `flake.lock` and `frontendNodeModulesHash` straight to `main`, but only when `spacebot-src` actually moved.
