# Optional hosted ChatGPT Work access

This is only for hosted ChatGPT Work/web access. For the ChatGPT desktop app on the same Mac, use `make run` and the local MCP connection in the [README](../README.md).

Hosted ChatGPT cannot reach `127.0.0.1` on your Mac directly. [OpenAI Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels) can connect the hosted app to this private server without opening an inbound network port. The Mac and both local processes must remain running for tools to work.

1. In [OpenAI Platform → Tunnels](https://platform.openai.com/settings/organization/tunnels), create a tunnel and associate it with the intended ChatGPT workspace. Save its `tunnel_...` ID. Creating a tunnel requires Tunnels Read + Manage; running it requires Tunnels Read + Use. Developer mode is a separate ChatGPT workspace permission.
2. Install the [official tunnel client](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels). Its [macOS troubleshooting guide](https://github.com/openai/tunnel-client/blob/master/docs/troubleshooting.md) recommends `brew install openai/tools/tunnel-client`.
3. In one Terminal window, start this server from its project folder with `make run`.
4. In another Terminal window, provide the runtime key without saving it in this repository or shell history. For zsh, enter the following, replacing the tunnel ID:

   ```sh
   read -s CONTROL_PLANE_API_KEY
   export CONTROL_PLANE_API_KEY
   tunnel-client init \
     --sample sample_mcp_remote_no_auth \
     --profile local-calendar \
     --tunnel-id tunnel_REPLACE_WITH_YOUR_ID \
     --mcp-server-url http://127.0.0.1:8765/mcp
   tunnel-client doctor --profile local-calendar --explain
   tunnel-client run --profile local-calendar
   ```

   Keep this window open too. On later days, start `make run`, provide the runtime key, then run `tunnel-client run --profile local-calendar`. If the CLI changes, follow `tunnel-client help quickstart`.
5. In [ChatGPT Plugins](https://chatgpt.com/plugins), create a developer-mode app with **Tunnel** as its connection, select or enter the tunnel ID, and review its discovered tools. Try a read-only request such as “List my reminder lists.”

If tool discovery fails, confirm that both processes are running, the tunnel is associated with the correct ChatGPT workspace, and `tunnel-client doctor --profile local-calendar --explain` reports readiness. Anyone given access to this ChatGPT connection can potentially read and change this Mac's reminders and calendars through the exposed tools.
