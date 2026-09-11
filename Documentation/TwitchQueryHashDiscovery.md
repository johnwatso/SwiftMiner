# Twitch Query Hash Discovery

SwiftMiner includes a small local tool for reading persisted-query hashes from
Twitch's own GraphQL request traffic. It does not contact Twitch, execute third-party
code, or read request headers. It only parses the operation name and 64-character
SHA-256 hash from a capture you provide.

## Capture the request in Safari

1. Enable Safari's **Develop** menu if it is not already visible.
2. Sign in to Twitch and open `https://www.twitch.tv/drops/campaigns`.
3. Choose **Develop → Show Web Inspector**, open **Network**, and reload the page.
4. Filter for `gql`, then press **Command-S** (or click **Export**) and save the
   network capture as HAR.
5. Run the tool against the exported file:

   ```sh
   python3 scripts/discover_twitch_query_hash.py "/actual/path/to/your-export.har"
   ```

The default operation is `ViewerDropsDashboard`. A successful result looks like:

```text
ViewerDropsDashboard: c16bb890cc8ce7647a96ee69cd313d423a378a3dedadf630a1017cde18975feb
```

To inspect all persisted queries present in the capture:

```sh
python3 scripts/discover_twitch_query_hash.py "/actual/path/to/your-export.har" --all
```

For scripts, use `--hash-only` or `--json`. A copied GraphQL request body can also
be passed directly, including through standard input:

```sh
pbpaste | python3 scripts/discover_twitch_query_hash.py - --hash-only
```

## Privacy

HAR files can contain Twitch authentication headers and cookies. The discovery tool
does not inspect or print those fields, but the HAR file itself remains sensitive.
Do not commit or share it, and delete it after extracting the hash. Copying only the
GraphQL request body is the lower-risk option because it excludes HTTP headers.
