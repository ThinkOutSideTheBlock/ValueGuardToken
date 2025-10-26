"""
VGT Data Collection Agent
Fetches price data from Pyth, position data from GMX, and economic indicators.
Implements Chat Protocol for user interaction via ASI:One.
"""

from datetime import datetime, timezone
from uuid import uuid4
import json
import os
from dotenv import load_dotenv
from uagents import Agent, Context, Model, Protocol
from uagents_core.contrib.protocols.chat import (
    ChatAcknowledgement,
    ChatMessage,
    EndSessionContent,
    StartSessionContent,
    TextContent,
    chat_protocol_spec,
)
import requests
from web3 import Web3

load_dotenv()

# Initialize agent with Mailbox for Agentverse hosting
agent = Agent(
    name="VGT Data Collection Agent",
    port=8001,
    seed=os.getenv("DATA_AGENT_SEED"),
    mailbox=True,
    publish_agent_details=True
)

# Configuration
PYTH_HERMES_URL = "https://hermes.pyth.network/v2/updates/price/latest"
ARBITRUM_RPC = os.getenv("ARBITRUM_RPC_URL")
GMX_READER_ADDRESS = os.getenv("GMX_READER_ADDRESS")
VGT_VAULT_ADDRESS = os.getenv("VGT_VAULT_ADDRESS")
ALPHA_VANTAGE_KEY = os.getenv("ALPHA_VANTAGE_KEY")

# Pyth price feed IDs
PRICE_FEEDS = {
    "gold": "0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2",
    "silver": "0xf2fb02c32b055c805e7238d628e5e9dadef274376114eb1f012337cabe93871e",
    "oil": "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace"
}

# Models for inter-agent communication
class MarketData(Model):
    timestamp: str
    prices: dict
    positions: dict
    economic_indicators: dict
    
class PortfolioQuery(Model):
    query_type: str  # "current_allocation", "nav", "performance"

# Web3 setup
w3 = Web3(Web3.HTTPProvider(ARBITRUM_RPC))

def create_text_chat(text: str, end_session: bool = False) -> ChatMessage:
    """Create a chat message for ASI:One interaction"""
    content = [TextContent(type="text", text=text)]
    if end_session:
        content.append(EndSessionContent(type="end-session"))
    return ChatMessage(
        timestamp=datetime.now(timezone.utc),
        msg_id=uuid4(),
        content=content,
    )

async def fetch_pyth_prices(ctx: Context) -> dict:
    """Fetch latest prices from Pyth Hermes API"""
    prices = {}
    try:
        for asset, feed_id in PRICE_FEEDS.items():
            response = requests.get(
                f"{PYTH_HERMES_URL}",
                params={"ids[]": feed_id}
            )
            if response.status_code == 200:
                data = response.json()
                if data.get("parsed"):
                    price_data = data["parsed"][0]["price"]
                    # Pyth prices have exponent, need to adjust
                    price = int(price_data["price"]) * (10 ** int(price_data["expo"]))
                    confidence = int(price_data["conf"]) * (10 ** int(price_data["expo"]))
                    
                    prices[asset] = {
                        "price": price,
                        "confidence": confidence,
                        "timestamp": data["parsed"][0]["metadata"]["timestamp"]
                    }
                    ctx.logger.info(f"Fetched {asset} price: ${price:.2f}")
        return prices
    except Exception as e:
        ctx.logger.error(f"Error fetching Pyth prices: {e}")
        return {}

async def fetch_gmx_positions(ctx: Context) -> dict:
    """Fetch current GMX position data via Web3"""
    positions = {}
    try:
        # Read from VGT Vault contract
        vault_contract = w3.eth.contract(
            address=Web3.to_checksum_address(VGT_VAULT_ADDRESS),
            abi=json.loads(os.getenv("VAULT_ABI"))
        )
        
        # Call getPositionBreakdown view function
        breakdown = vault_contract.functions.getPositionBreakdown().call()
        
        positions = {
            "gold": {
                "exposure_usd": breakdown[0] / 1e6,  # Convert from 6 decimals
                "weight": 0  # Will calculate after getting total
            },
            "silver": {
                "exposure_usd": breakdown[1] / 1e6,
                "weight": 0
            },
            "oil": {
                "exposure_usd": breakdown[2] / 1e6,
                "weight": 0
            },
            "cash": {
                "amount_usd": breakdown[3] / 1e6
            },
            "unrealized_pnl": breakdown[4] / 1e6
        }
        
        # Calculate total exposure and weights
        total_exposure = sum(p["exposure_usd"] for k, p in positions.items() if "exposure_usd" in p)
        for asset in ["gold", "silver", "oil"]:
            positions[asset]["weight"] = positions[asset]["exposure_usd"] / total_exposure if total_exposure > 0 else 0
        
        ctx.logger.info(f"Fetched GMX positions: {positions}")
        return positions
        
    except Exception as e:
        ctx.logger.error(f"Error fetching GMX positions: {e}")
        return {}

async def fetch_economic_indicators(ctx: Context) -> dict:
    """Fetch economic indicators from APIs"""
    indicators = {}
    try:
        # Fetch CPI data (simplified - in production use FRED API)
        # For hackathon, use mock data or simple API
        indicators["cpi_annual_rate"] = 3.2  # Mock data
        indicators["interest_rate"] = 5.5    # Mock data
        indicators["vix_volatility"] = 15.2  # Mock data
        
        # Could add news sentiment analysis here
        # For now, use placeholder
        indicators["market_sentiment"] = "neutral"
        indicators["geopolitical_risk"] = "low"
        
        ctx.logger.info(f"Fetched economic indicators: {indicators}")
        return indicators
        
    except Exception as e:
        ctx.logger.error(f"Error fetching economic indicators: {e}")
        return {}

# Chat Protocol for ASI:One interaction
chat_proto = Protocol(spec=chat_protocol_spec)

@chat_proto.on_message(ChatMessage)
async def handle_chat_message(ctx: Context, sender: str, msg: ChatMessage):
    """Handle incoming chat messages from ASI:One users"""
    ctx.storage.set(str(ctx.session), sender)
    
    # Send acknowledgement
    await ctx.send(
        sender,
        ChatAcknowledgement(
            timestamp=datetime.now(timezone.utc),
            acknowledged_msg_id=msg.msg_id
        ),
    )
    
    for item in msg.content:
        if isinstance(item, StartSessionContent):
            ctx.logger.info(f"Started chat session with {sender}")
            await ctx.send(
                sender,
                create_text_chat(
                    "Hello! I'm the VGT Data Collection Agent. I can provide information about:\n"
                    "- Current portfolio allocation\n"
                    "- Asset prices (gold, silver, oil)\n"
                    "- NAV and performance\n"
                    "- Market conditions\n\n"
                    "What would you like to know?"
                )
            )
            
        elif isinstance(item, TextContent):
            user_query = item.text.strip().lower()
            ctx.logger.info(f"User query from {sender}: {user_query}")
            
            try:
                # Parse user intent and fetch data
                if "allocation" in user_query or "portfolio" in user_query:
                    positions = await fetch_gmx_positions(ctx)
                    response = f"**Current Portfolio Allocation:**\n\n"
                    response += f"🥇 Gold: {positions['gold']['weight']*100:.1f}% (${positions['gold']['exposure_usd']:,.0f})\n"
                    response += f"🥈 Silver: {positions['silver']['weight']*100:.1f}% (${positions['silver']['exposure_usd']:,.0f})\n"
                    response += f"🛢️ Oil: {positions['oil']['weight']*100:.1f}% (${positions['oil']['exposure_usd']:,.0f})\n"
                    response += f"💵 Cash Reserve: ${positions['cash']['amount_usd']:,.0f}\n"
                    response += f"\n📊 Unrealized P&L: ${positions['unrealized_pnl']:,.0f}"
                    
                elif "price" in user_query or "cost" in user_query:
                    prices = await fetch_pyth_prices(ctx)
                    response = f"**Current Asset Prices:**\n\n"
                    for asset, data in prices.items():
                        response += f"{asset.title()}: ${data['price']:,.2f}\n"
                        
                elif "market" in user_query or "condition" in user_query:
                    indicators = await fetch_economic_indicators(ctx)
                    response = f"**Market Conditions:**\n\n"
                    response += f"CPI Inflation: {indicators['cpi_annual_rate']}%\n"
                    response += f"Interest Rate: {indicators['interest_rate']}%\n"
                    response += f"VIX Volatility: {indicators['vix_volatility']}\n"
                    response += f"Sentiment: {indicators['market_sentiment'].title()}\n"
                    response += f"Geopolitical Risk: {indicators['geopolitical_risk'].title()}"
                    
                else:
                    response = "I can help you with portfolio allocation, current prices, or market conditions. Please ask about one of these topics."
                
                await ctx.send(sender, create_text_chat(response))
                
            except Exception as e:
                ctx.logger.error(f"Error processing query: {e}")
                await ctx.send(
                    sender,
                    create_text_chat("Sorry, I encountered an error. Please try again.")
                )

@chat_proto.on_message(ChatAcknowledgement)
async def handle_ack(ctx: Context, sender: str, msg: ChatAcknowledgement):
    ctx.logger.info(f"Received acknowledgement from {sender}")

# Periodic data collection protocol (sends to Market Intelligence Agent)
data_collection_proto = Protocol(name="data-collection")

@data_collection_proto.on_interval(period=300.0)  # Every 5 minutes
async def collect_and_broadcast_data(ctx: Context):
    """Periodically collect data and send to Market Intelligence Agent"""
    ctx.logger.info("Starting periodic data collection...")
    
    # Fetch all data
    prices = await fetch_pyth_prices(ctx)
    positions = await fetch_gmx_positions(ctx)
    indicators = await fetch_economic_indicators(ctx)
    
    if prices and positions and indicators:
        # Package data for Market Intelligence Agent
        market_data = MarketData(
            timestamp=datetime.now(timezone.utc).isoformat(),
            prices=prices,
            positions=positions,
            economic_indicators=indicators
        )
        
        # Send to Market Intelligence Agent
        market_intel_address = ctx.storage.get("market_intel_agent_address")
        if market_intel_address:
            await ctx.send(market_intel_address, market_data)
            ctx.logger.info(f"Sent market data to Market Intelligence Agent")
        else:
            ctx.logger.warning("Market Intelligence Agent address not configured")
    else:
        ctx.logger.error("Failed to collect complete market data")

# Include protocols
agent.include(chat_proto, publish_manifest=True)
agent.include(data_collection_proto)

# Startup handler
@agent.on_event("startup")
async def startup(ctx: Context):
    ctx.logger.info("VGT Data Collection Agent started")
    ctx.logger.info(f"Agent address: {ctx.agent.address}")
    
    # Store Market Intelligence Agent address (set via environment)
    market_intel_addr = os.getenv("MARKET_INTEL_AGENT_ADDRESS")
    if market_intel_addr:
        ctx.storage.set("market_intel_agent_address", market_intel_addr)

if __name__ == "__main__":
    agent.run()
