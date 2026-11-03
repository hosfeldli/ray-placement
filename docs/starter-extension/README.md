# Lima starter extension

This checked-in v3 form counts lines in a selected file.

1. In Lima → Extension Library → Add → Install a Folder, choose this folder.
2. Review the capabilities and select Approve & Enable.
3. Find Count Lines in Search, select a file, and run it.

For a new extension, prefer Build in the library, or run from the Lima repository:

```sh
swift run lima-extension init ./my-tools --id local.example.my-tools --name "My Tools" --template form
swift run lima-extension check ./my-tools
```

Use Link a Development Folder to edit without repeated copying. Keep IDs stable. See `docs/EXTENSIONS.md` for the complete contract and CLI workflow.
