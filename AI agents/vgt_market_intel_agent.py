"""
VGT Market Intelligence Agent
Analyzes market data using MeTTa knowledge graphs to determine market regimes
and recommend portfolio adjustments.
"""

import os
from dotenv import load_dotenv
from uagents import Agent, Context, Model, Protocol
from hyperon import MeTTa
from metta.market_knowledge import initialize_market_knowledge
from metta.market_analysis import MarketAnalyzer

load_dotenv()

# Initialize agent
agent = Agent(
    name="VGT Market Intelligence Agent",
    port=8002,
    seed=os.getenv("MARKET_INTEL_SEED"),
    mailbox=True,
    publish_agent_details=True
)

# Models
class MarketData(Model):
    timestamp: str
    prices: dict
    positions: dict
    economic_indicators: dict

class MarketAnalysis(Model):
    timestamp: str
    market_regime: str  # "bullish_gold", "high_volatility", "inflationary", etc.
    recommended_adjustments: dict  # {"gold": +5, "silver": +2, "oil": -7}
    reasoning: str
    confidence: float

# Initialize MeTTa knowledge graph
metta = MeTTa()
initialize_market_knowledge(metta)
analyzer = MarketAnalyzer(metta)

# Protocol for receiving data and sending analysis
analysis_proto = Protocol(name="market-analysis")

@analysis_proto.on_message(MarketData)
async def analyze_market_data(ctx: Context, sender: str, msg: MarketData):
    """Receive market data and perform MeTTa-based analysis"""
    ctx.logger.info(f"Received market data from {sender}")
    
    try:
        # Extract key metrics
        gold_price = msg.prices.get("gold", {}).get("price", 0)
        silver_price = msg.prices.get("silver", {}).get("price", 0)
        oil_price = msg.prices.get("oil", {}).get("price", 0)
        
        cpi = msg.economic_indicators.get("cpi_annual_rate", 0)
        interest_rate = msg.economic_indicators.get("interest_rate", 0)
        volatility = msg.economic_indicators.get("vix_volatility", 0)
        
        current_weights = {
            "gold": msg.positions.get("gold", {}).get("weight", 0),
            "silver": msg.positions.get("silver", {}).get("weight", 0),
            "oil": msg.positions.get("oil", {}).get("weight", 0)
        }
        
        ctx.logger.info(f"Current weights: Gold {current_weights['gold']:.1%}, "
                       f"Silver {current_weights['silver']:.1%}, Oil {current_weights['oil']:.1%}")
        
        # Perform MeTTa reasoning
        market_regime = analyzer.determine_market_regime(cpi, interest_rate, volatility)
        ctx.logger.info(f"Determined market regime: {market_regime}")
        
        # Get recommended asset preferences based on regime
        asset_preferences = analyzer.get_regime_preferences(market_regime)
        ctx.logger.info(f"Asset preferences for {market_regime}: {asset_preferences}")
        
        # Calculate recommended adjustments
        target_weights = analyzer.calculate_target_weights(
            market_regime,
            current_weights,
            cpi,
            volatility
        )
        
        # Calculate adjustments (percentage points)
        adjustments = {
            asset: (target_weights[asset] - current_weights[asset]) * 100
            for asset in ["gold", "silver", "oil"]
        }
        
        # Generate reasoning explanation
        reasoning = analyzer.explain_reasoning(
            market_regime,
            adjustments,
            cpi,
            interest_rate,
            volatility
        )
        
        # Calculate confidence based on market clarity
        confidence = analyzer.calculate_confidence(volatility, cpi)
        
        ctx.logger.info(f"Recommended adjustments: {adjustments}")
        ctx.logger.info(f"Confidence: {confidence:.2f}")
        
        # Package analysis
        analysis = MarketAnalysis(
            timestamp=msg.timestamp,
            market_regime=market_regime,
            recommended_adjustments=adjustments,
            reasoning=reasoning,
            confidence=confidence
        )
        
        # Send to Rebalancer Agent
        rebalancer_address = ctx.storage.get("rebalancer_agent_address")
        if rebalancer_address:
            await ctx.send(rebalancer_address, analysis)
            ctx.logger.info("Sent analysis to Rebalancer Agent")
        else:
            ctx.logger.warning("Rebalancer Agent address not configured")
            
    except Exception as e:
        ctx.logger.error(f"Error analyzing market data: {e}")

agent.include(analysis_proto)

@agent.on_event("startup")
async def startup(ctx: Context):
    ctx.logger.info("VGT Market Intelligence Agent started")
    ctx.logger.info(f"Agent address: {ctx.agent.address}")
    
    # Store Rebalancer Agent address
    rebalancer_addr = os.getenv("REBALANCER_AGENT_ADDRESS")
    if rebalancer_addr:
        ctx.storage.set("rebalancer_agent_address", rebalancer_addr)
    
    # Log MeTTa knowledge loaded
    ctx.logger.info("MeTTa market knowledge graph initialized")

if __name__ == "__main__":
    agent.run()
