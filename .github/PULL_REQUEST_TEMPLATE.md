## What changed and why

<!-- Describe the change and its motivation. -->

## Checklist

- [ ] `make shellcheck` passes
- [ ] `make rpm && make lint` passes
- [ ] `python3 -c "import tomllib; tomllib.load(open('blueprint.toml', 'rb'))"` passes
- [ ] `blueprint.toml` version bumped (if blueprint changed)
- [ ] RPM spec `Version:` bumped (if RPM changed)
