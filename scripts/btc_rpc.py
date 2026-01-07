#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "httpx>=0.27.0",
#   "typer>=0.9.0",
#   "rich>=13.0.0",
# ]
# ///
"""
Bitcoin RPC CLI - Query blockchain info from public RPC endpoints.

Usage:
    uv run btc_rpc.py <command> [options]

Commands:
    info        Get blockchain info (height, best block, chainwork)
    block       Get block by height or hash
    tx          Get transaction by txid
    mempool     Get mempool info
    peers       Get network peer info
    compare     Compare local node with public RPC
    endpoints   List available RPC endpoints

Examples:
    uv run btc_rpc.py info --network testnet3
    uv run btc_rpc.py info --network testnet4
    uv run btc_rpc.py block --network testnet3 --height 0
    uv run btc_rpc.py compare --network testnet3 --local http://127.0.0.1:18332
"""

import json
import sys
from typing import Optional

import httpx
import typer
from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from rich import box

app = typer.Typer(help="Bitcoin RPC CLI for querying public blockchain endpoints")
console = Console()

# ============================================================================
# Public RPC Endpoints
# ============================================================================

ENDPOINTS = {
    "mainnet": {
        "name": "Bitcoin Mainnet",
        "rpc_url": "https://bitcoin-mainnet-rpc.publicnode.com",
        "explorer": "https://mempool.space",
        "default_port": 8333,
        "rpc_port": 8332,
        "genesis_hash": "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f",
    },
    "testnet3": {
        "name": "Bitcoin Testnet3",
        "rpc_url": "https://bitcoin-testnet-rpc.publicnode.com",
        "explorer": "https://mempool.space/testnet",
        "default_port": 18333,
        "rpc_port": 18332,
        "genesis_hash": "000000000933ea01ad0ee984209779baaec3ced90fa3f408719526f8d77f4943",
    },
    "testnet4": {
        "name": "Bitcoin Testnet4 (BIP-94)",
        "rpc_url": "https://bitcoin-testnet4.gateway.tatum.io",
        "explorer": "https://mempool.space/testnet4",
        "default_port": 48333,
        "rpc_port": 48332,
        "genesis_hash": "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043",
    },
    "signet": {
        "name": "Bitcoin Signet",
        "rpc_url": None,  # No public RPC available yet
        "explorer": "https://mempool.space/signet",
        "default_port": 38333,
        "rpc_port": 38332,
        "genesis_hash": "00000008819873e925422c1ff0f99f7cc9bbb232af63a077a480a3633bee1ef6",
    },
}

# Aliases for convenience
NETWORK_ALIASES = {
    "main": "mainnet",
    "test": "testnet3",
    "testnet": "testnet3",
    "test3": "testnet3",
    "test4": "testnet4",
}


def resolve_network(network: str) -> str:
    """Resolve network alias to canonical name."""
    network = network.lower()
    return NETWORK_ALIASES.get(network, network)


def get_endpoint(network: str) -> dict:
    """Get endpoint config for network."""
    network = resolve_network(network)
    if network not in ENDPOINTS:
        console.print(f"[red]Unknown network: {network}[/red]")
        console.print(f"[dim]Available: {', '.join(ENDPOINTS.keys())}[/dim]")
        raise typer.Exit(1)
    return ENDPOINTS[network]


def rpc_call(url: str, method: str, params: list = None, timeout: float = 30.0) -> dict:
    """Make JSON-RPC call to Bitcoin node."""
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params or [],
    }

    try:
        with httpx.Client(timeout=timeout) as client:
            response = client.post(
                url,
                json=payload,
                headers={"Content-Type": "application/json"},
            )
            response.raise_for_status()
            data = response.json()

            if "error" in data and data["error"]:
                console.print(f"[red]RPC Error: {data['error']}[/red]")
                raise typer.Exit(1)

            return data.get("result", data)
    except httpx.HTTPError as e:
        console.print(f"[red]HTTP Error: {e}[/red]")
        raise typer.Exit(1)
    except json.JSONDecodeError as e:
        console.print(f"[red]JSON Decode Error: {e}[/red]")
        raise typer.Exit(1)


# ============================================================================
# Commands
# ============================================================================

@app.command()
def endpoints():
    """List available RPC endpoints for each network."""
    table = Table(title="Bitcoin Network RPC Endpoints", box=box.ROUNDED)
    table.add_column("Network", style="cyan")
    table.add_column("RPC URL", style="green")
    table.add_column("Explorer", style="blue")
    table.add_column("P2P Port", style="dim")
    table.add_column("RPC Port", style="dim")

    for network, config in ENDPOINTS.items():
        rpc_url = config["rpc_url"] or "[dim]Not available[/dim]"
        table.add_row(
            config["name"],
            rpc_url,
            config["explorer"],
            str(config["default_port"]),
            str(config["rpc_port"]),
        )

    console.print(table)

    console.print("\n[bold]Genesis Hashes:[/bold]")
    for network, config in ENDPOINTS.items():
        console.print(f"  {network}: [dim]{config['genesis_hash']}[/dim]")


@app.command()
def info(
    network: str = typer.Option("testnet3", "--network", "-n", help="Network: mainnet, testnet3, testnet4, signet"),
    raw: bool = typer.Option(False, "--raw", "-r", help="Output raw JSON"),
):
    """Get blockchain info from public RPC."""
    endpoint = get_endpoint(network)

    if not endpoint["rpc_url"]:
        console.print(f"[yellow]No public RPC available for {endpoint['name']}[/yellow]")
        raise typer.Exit(1)

    result = rpc_call(endpoint["rpc_url"], "getblockchaininfo")

    if raw:
        print(json.dumps(result, indent=2))
        return

    # Format nice output
    chain = result.get("chain", "unknown")
    blocks = result.get("blocks", 0)
    headers = result.get("headers", 0)
    best_hash = result.get("bestblockhash", "")
    difficulty = result.get("difficulty", 0)
    chainwork = result.get("chainwork", "")
    verification = result.get("verificationprogress", 0)
    ibd = result.get("initialblockdownload", False)

    panel_content = f"""[bold]Chain:[/bold] {chain}
[bold]Blocks:[/bold] {blocks:,}
[bold]Headers:[/bold] {headers:,}
[bold]Best Block:[/bold] {best_hash[:16]}...{best_hash[-8:]}
[bold]Difficulty:[/bold] {difficulty:,.2f}
[bold]Chainwork:[/bold] {chainwork[:20]}...
[bold]Verification:[/bold] {verification * 100:.4f}%
[bold]IBD:[/bold] {ibd}"""

    console.print(Panel(
        panel_content,
        title=f"[cyan]{endpoint['name']}[/cyan]",
        subtitle=f"[dim]{endpoint['rpc_url']}[/dim]",
    ))


@app.command()
def block(
    network: str = typer.Option("testnet3", "--network", "-n", help="Network"),
    height: Optional[int] = typer.Option(None, "--height", "-h", help="Block height"),
    hash: Optional[str] = typer.Option(None, "--hash", help="Block hash"),
    raw: bool = typer.Option(False, "--raw", "-r", help="Output raw JSON"),
):
    """Get block by height or hash."""
    endpoint = get_endpoint(network)

    if not endpoint["rpc_url"]:
        console.print(f"[yellow]No public RPC available for {endpoint['name']}[/yellow]")
        raise typer.Exit(1)

    if height is None and hash is None:
        console.print("[red]Specify either --height or --hash[/red]")
        raise typer.Exit(1)

    # Get block hash if height provided
    block_hash = hash
    if height is not None:
        block_hash = rpc_call(endpoint["rpc_url"], "getblockhash", [height])

    # Get block data
    result = rpc_call(endpoint["rpc_url"], "getblock", [block_hash, 1])

    if raw:
        print(json.dumps(result, indent=2))
        return

    # Format output
    console.print(Panel(
        f"""[bold]Hash:[/bold] {result.get('hash', '')}
[bold]Height:[/bold] {result.get('height', 0):,}
[bold]Version:[/bold] {result.get('version', 0)}
[bold]Time:[/bold] {result.get('time', 0)}
[bold]Bits:[/bold] {result.get('bits', '')}
[bold]Nonce:[/bold] {result.get('nonce', 0)}
[bold]Difficulty:[/bold] {result.get('difficulty', 0):,.2f}
[bold]Tx Count:[/bold] {len(result.get('tx', []))}
[bold]Size:[/bold] {result.get('size', 0):,} bytes
[bold]Weight:[/bold] {result.get('weight', 0):,}
[bold]Prev Block:[/bold] {result.get('previousblockhash', 'None')[:32]}...""",
        title=f"[cyan]Block {result.get('height', 'Unknown')}[/cyan]",
    ))


@app.command()
def tx(
    txid: str = typer.Argument(..., help="Transaction ID"),
    network: str = typer.Option("testnet3", "--network", "-n", help="Network"),
    raw: bool = typer.Option(False, "--raw", "-r", help="Output raw JSON"),
):
    """Get transaction by txid."""
    endpoint = get_endpoint(network)

    if not endpoint["rpc_url"]:
        console.print(f"[yellow]No public RPC available for {endpoint['name']}[/yellow]")
        raise typer.Exit(1)

    result = rpc_call(endpoint["rpc_url"], "getrawtransaction", [txid, True])

    if raw:
        print(json.dumps(result, indent=2))
        return

    console.print(Panel(
        f"""[bold]TXID:[/bold] {result.get('txid', '')}
[bold]Version:[/bold] {result.get('version', 0)}
[bold]Size:[/bold] {result.get('size', 0):,} bytes
[bold]VSize:[/bold] {result.get('vsize', 0):,} vbytes
[bold]Weight:[/bold] {result.get('weight', 0):,}
[bold]Locktime:[/bold] {result.get('locktime', 0)}
[bold]Inputs:[/bold] {len(result.get('vin', []))}
[bold]Outputs:[/bold] {len(result.get('vout', []))}
[bold]Confirmations:[/bold] {result.get('confirmations', 0)}
[bold]Block Hash:[/bold] {result.get('blockhash', 'Unconfirmed')[:32]}...""",
        title="[cyan]Transaction[/cyan]",
    ))


@app.command()
def mempool(
    network: str = typer.Option("testnet3", "--network", "-n", help="Network"),
    raw: bool = typer.Option(False, "--raw", "-r", help="Output raw JSON"),
):
    """Get mempool info."""
    endpoint = get_endpoint(network)

    if not endpoint["rpc_url"]:
        console.print(f"[yellow]No public RPC available for {endpoint['name']}[/yellow]")
        raise typer.Exit(1)

    result = rpc_call(endpoint["rpc_url"], "getmempoolinfo")

    if raw:
        print(json.dumps(result, indent=2))
        return

    console.print(Panel(
        f"""[bold]Size:[/bold] {result.get('size', 0):,} transactions
[bold]Bytes:[/bold] {result.get('bytes', 0):,}
[bold]Usage:[/bold] {result.get('usage', 0):,} bytes
[bold]Max Size:[/bold] {result.get('maxmempool', 0):,} bytes
[bold]Min Fee:[/bold] {result.get('mempoolminfee', 0)} BTC/kvB
[bold]Min Relay Fee:[/bold] {result.get('minrelaytxfee', 0)} BTC/kvB""",
        title=f"[cyan]{endpoint['name']} Mempool[/cyan]",
    ))


@app.command()
def compare(
    network: str = typer.Option("testnet3", "--network", "-n", help="Network"),
    local: Optional[str] = typer.Option(None, "--local", "-l", help="Local node RPC URL (auto-detects from network if not specified)"),
):
    """Compare local node with public RPC to check sync progress."""
    endpoint = get_endpoint(network)

    # Auto-detect local RPC URL based on network if not specified
    if local is None:
        local = f"http://127.0.0.1:{endpoint['rpc_port']}"
        console.print(f"[dim]Using local RPC: {local}[/dim]")

    if not endpoint["rpc_url"]:
        console.print(f"[yellow]No public RPC available for {endpoint['name']}[/yellow]")
        raise typer.Exit(1)

    # Get public chain info
    console.print("[dim]Fetching public chain info...[/dim]")
    try:
        public_info = rpc_call(endpoint["rpc_url"], "getblockchaininfo")
    except Exception as e:
        console.print(f"[red]Failed to fetch public chain info: {e}[/red]")
        raise typer.Exit(1)

    # Get local chain info
    console.print("[dim]Fetching local chain info...[/dim]")
    try:
        local_info = rpc_call(local, "getblockchaininfo")
    except Exception as e:
        console.print(f"[red]Failed to fetch local chain info: {e}[/red]")
        console.print(f"[dim]Is your local node running at {local}?[/dim]")
        raise typer.Exit(1)

    # Compare
    pub_blocks = public_info.get("blocks", 0)
    pub_headers = public_info.get("headers", 0)
    local_blocks = local_info.get("blocks", 0)
    local_headers = local_info.get("headers", 0)

    blocks_diff = pub_blocks - local_blocks
    headers_diff = pub_headers - local_headers

    blocks_pct = (local_blocks / pub_blocks * 100) if pub_blocks > 0 else 0
    headers_pct = (local_headers / pub_headers * 100) if pub_headers > 0 else 0

    # Status colors
    blocks_color = "green" if blocks_diff <= 0 else ("yellow" if blocks_diff < 100 else "red")
    headers_color = "green" if headers_diff <= 0 else ("yellow" if headers_diff < 1000 else "red")

    # Check for issues
    issues = []
    if local_headers > pub_headers * 1.1:  # More than 10% ahead
        issues.append("[red]WARNING: Local headers significantly ahead of public chain - possible invalid chain![/red]")
    if local_info.get("bestblockhash") != public_info.get("bestblockhash") and local_blocks == pub_blocks:
        issues.append("[yellow]WARNING: Same height but different best block - possible chain split![/yellow]")

    table = Table(title=f"Sync Comparison: {endpoint['name']}", box=box.ROUNDED)
    table.add_column("Metric", style="cyan")
    table.add_column("Public", style="green")
    table.add_column("Local", style="blue")
    table.add_column("Diff", style="yellow")
    table.add_column("Progress")

    table.add_row(
        "Headers",
        f"{pub_headers:,}",
        f"{local_headers:,}",
        f"[{headers_color}]{headers_diff:+,}[/{headers_color}]",
        f"[{headers_color}]{headers_pct:.2f}%[/{headers_color}]",
    )
    table.add_row(
        "Blocks",
        f"{pub_blocks:,}",
        f"{local_blocks:,}",
        f"[{blocks_color}]{blocks_diff:+,}[/{blocks_color}]",
        f"[{blocks_color}]{blocks_pct:.2f}%[/{blocks_color}]",
    )
    table.add_row(
        "Best Block",
        f"{public_info.get('bestblockhash', '')[:16]}...",
        f"{local_info.get('bestblockhash', '')[:16]}...",
        "",
        "",
    )
    table.add_row(
        "IBD",
        str(public_info.get("initialblockdownload", False)),
        str(local_info.get("initialblockdownload", True)),
        "",
        "",
    )

    console.print(table)

    if issues:
        console.print()
        for issue in issues:
            console.print(issue)

    # Summary
    if headers_diff <= 0 and blocks_diff <= 0:
        console.print("\n[green]Node is fully synced![/green]")
    elif headers_diff <= 0:
        console.print(f"\n[yellow]Headers synced, blocks behind by {blocks_diff:,}[/yellow]")
    else:
        console.print(f"\n[yellow]Syncing... Headers: {headers_pct:.1f}%, Blocks: {blocks_pct:.1f}%[/yellow]")


@app.command()
def genesis(
    network: str = typer.Option("testnet3", "--network", "-n", help="Network"),
    raw: bool = typer.Option(False, "--raw", "-r", help="Output raw JSON"),
):
    """Get genesis block info."""
    endpoint = get_endpoint(network)

    if not endpoint["rpc_url"]:
        console.print(f"[yellow]No public RPC available for {endpoint['name']}[/yellow]")
        # Still show expected genesis hash
        console.print(f"[dim]Expected genesis hash: {endpoint['genesis_hash']}[/dim]")
        raise typer.Exit(1)

    # Get genesis block (height 0)
    block_hash = rpc_call(endpoint["rpc_url"], "getblockhash", [0])
    result = rpc_call(endpoint["rpc_url"], "getblock", [block_hash, 1])

    if raw:
        print(json.dumps(result, indent=2))
        return

    # Verify genesis hash matches expected
    matches = "Yes" if block_hash == endpoint["genesis_hash"] else "NO - MISMATCH!"
    match_color = "green" if block_hash == endpoint["genesis_hash"] else "red"

    console.print(Panel(
        f"""[bold]Hash:[/bold] {result.get('hash', '')}
[bold]Expected:[/bold] {endpoint['genesis_hash']}
[bold]Match:[/bold] [{match_color}]{matches}[/{match_color}]
[bold]Version:[/bold] {result.get('version', 0)}
[bold]Time:[/bold] {result.get('time', 0)}
[bold]Bits:[/bold] {result.get('bits', '')}
[bold]Nonce:[/bold] {result.get('nonce', 0)}
[bold]Merkle Root:[/bold] {result.get('merkleroot', '')}""",
        title=f"[cyan]{endpoint['name']} Genesis Block[/cyan]",
    ))


@app.command()
def difficulty(
    network: str = typer.Option("testnet3", "--network", "-n", help="Network"),
):
    """Get current difficulty."""
    endpoint = get_endpoint(network)

    if not endpoint["rpc_url"]:
        console.print(f"[yellow]No public RPC available for {endpoint['name']}[/yellow]")
        raise typer.Exit(1)

    result = rpc_call(endpoint["rpc_url"], "getdifficulty")
    console.print(f"[cyan]{endpoint['name']}[/cyan] difficulty: [green]{result:,.8f}[/green]")


@app.command()
def height(
    network: str = typer.Option("testnet3", "--network", "-n", help="Network"),
):
    """Get current block height (quick check)."""
    endpoint = get_endpoint(network)

    if not endpoint["rpc_url"]:
        console.print(f"[yellow]No public RPC available for {endpoint['name']}[/yellow]")
        raise typer.Exit(1)

    result = rpc_call(endpoint["rpc_url"], "getblockcount")
    console.print(f"[cyan]{endpoint['name']}[/cyan] height: [green]{result:,}[/green]")


if __name__ == "__main__":
    app()
