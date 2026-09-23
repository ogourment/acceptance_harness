# AcceptanceHarness

AcceptanceHarness records browser journeys, screenshots, source HTML, and review
activity for Phoenix applications. Its standalone `xopen`, `mdopen`, and
`acceptance-review` tools can open evidence without a Phoenix application.

## Try the tools

Install Python 3.9 or newer, then open an existing review bundle:

```sh
bin/xopen --watch /absolute/path/review.html
```

For Phoenix integration, see the [integration guide](docs/phoenix_acceptance_harness_recipe.md).
The [standalone guide](docs/standalone.md) covers platform prerequisites, and
the [reference](docs/reference.md) covers configuration and Mix commands.

## Contribute

This GitHub repository is a public code mirror. The authoritative development
repository is on [Framagit](https://framagit.org/olivierg/acceptance_harness).
The Framagit repository also contains private review evidence, so its complete
history and private files are intentionally absent here. `SOURCE-REVISION`
identifies the Framagit `main` commit used for the current public snapshot.

Please [open a pull request on GitHub](CONTRIBUTING.md). A maintainer will bring
accepted changes into Framagit first; the public mirror will then update from
Framagit. Do not merge directly into this mirror's `main` branch. This mirror
publishes source code for review and contribution; release tags remain on the
authoritative repository.

## License

Apache 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). Third-party components
retain their own licenses.
