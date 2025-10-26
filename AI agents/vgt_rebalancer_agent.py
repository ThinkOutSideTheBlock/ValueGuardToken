"""
VGT Rebalancer Agent
Receives market analysis and decides whether to execute rebalancing.
Uses MeTTa knowledge for portfolio optimization logic.
"""

import os
from dotenv import load_dotenv
from uagents import Agent, Context, Model, Protocol
from hyperon import MeTTa
from metta.portfolio_knowledge import initialize_portfolio_knowledge
from metta.rebalancing_logic import RebalancingEngine

load_dotenv()

# Initialize agent
agent = Agent(
    name="VGT Rebalancer Agent",
    port=8003,
    seed=os.getenv("REBALANCER_SEED"),
    mailbox=True,
    publish_agent_details=True
)

# Models
class MarketAnalysis(Model):
    timestamp: str
    market_regime: str
    recommended_adjustments: dict
    reasoning: str
    confidence: float

class RebalancingDecision(Model):
    timestamp: str
    should_rebalance: bool
    new_weights: dict  # {"gold": 0.42, "silver": 0.23, "oil": 0.25, "cash": 0.10}
    reasoning: str
    estimated_cost: float
    risk_score: float

# Initialize MeTTa knowledge graph
metta = MeTTa()
initialize_portfolio_knowledge(metta)
rebalancing_engine = RebalancingEngine(metta)

# Configuration
DRIFT_THRESHOLD = 0.03  # 3% absolute drift triggers rebalancing
MIN_CONFIDENCE = 0.6    # Minimum confidence to rebalance
MAX_SINGLE_POSITION = 0.50  # No asset > 50%
MIN_CASH_BUFFER = 0.10  # Always keep 10% cash

rebalancing_proto = Protocol(name="rebalancing")

@rebalancing_proto.on_message(MarketAnalysis)
async def process_market_analysis(ctx: Context, sender: str, msg: MarketAnalysis):
    """Receive market analysis and decide on rebalancing"""
    ctx.logger.info(f"Received market analysis from {sender}")
    ctx.logger.info(f"Market regime: {msg.market_regime}, Confidence: {msg.confidence:.2f}")
    
    try:
        # Check if any adjustment exceeds drift threshold
        max_adjustment = max(abs(adj) for adj in msg.recommended_adjustments.values())
        ctx.logger.info(f"Maximum recommended adjustment: {max_adjustment:.1f}%")
        
        if max_adjustment < DRIFT_THRESHOLD * 100:
            ctx.logger.info(f"No rebalancing needed - max drift {max_adjustment:.1f}% below threshold {DRIFT_THRESHOLD*100}%")
            return
        
        # Check confidence level
        if msg.confidence < MIN_CONFIDENCE:
            ctx.logger.info(f"Confidence {msg.confidence:.2f} below minimum {MIN_CONFIDENCE} - deferring rebalancing")
            return
        
        # Use MeTTa to calculate optimal new weights
        new_weights = rebalancing_engine.calculate_optimal_weights(
            msg.market_regime,
            msg.recommended_adjustments,
            msg.confidence
        )
        
        ctx.logger.info(f"Calculated new weights: {new_weights}")
        
        # Validate constraints using MeTTa
        is_valid, violations = rebalancing_engine.validate_constraints(
            new_weights,
            MAX_SINGLE_POSITION,
            MIN_CASH_BUFFER
        )
        
        if not is_valid:
            ctx.logger.warning(f"Constraint violations: {violations}")
            # Adjust weights to satisfy constraints
            new_weights = rebalancing_engine.adjust_for_constraints(
                new_weights,
                MAX_SINGLE_POSITION,
                MIN_CASH_BUFFER
            )
            ctx.logger.info(f"Adjusted weights after constraints: {new_weights}")
        
        # Estimate execution cost (gas + slippage)
        estimated_cost = rebalancing_engine.estimate_execution_cost(
            msg.recommended_adjustments
        )
        
        # Calculate risk score
        risk_score = rebalancing_engine.calculate_risk_score(
            new_weights,
            msg.market_regime
        )
        
        ctx.logger.info(f"Estimated cost: ${estimated_cost:.2f}, Risk score: {risk_score:.2f}")
        
        # Generate reasoning using MeTTa
        reasoning = rebalancing_engine.generate_reasoning(
            msg.market_regime,
            new_weights,
            msg.reasoning
        )
        
        # Create rebalancing decision
        decision = RebalancingDecision(
            timestamp=msg.timestamp,
            should_rebalance=True,
            new_weights=new_weights,
            reasoning=reasoning,
            estimated_cost=estimated_cost,
            risk_score=risk_score
        )
        
        # Send to Executor Agent
        executor_address = ctx.storage.get("executor_agent_address")
        if executor_address:
            await ctx.send(executor_address, decision)
            ctx.logger.info("Sent rebalancing decision to Executor Agent")
        else:
            ctx.logger.warning("Executor Agent address not configured")
            
        # Log decision
        ctx.storage.set(f"rebalancing_{msg.timestamp}", decision.model_dump_json())
        
    except Exception as e:
        ctx.logger.error(f"Error processing market analysis: {e}")

agent.include(rebalancing_proto)

@agent.on_event("startup")
async def startup(ctx: Context):
    ctx.logger.info("VGT Rebalancer Agent started")
    ctx.logger.info(f"Agent address: {ctx.agent.address}")
    
    # Store Executor Agent address
    executor_addr = os.getenv("EXECUTOR_AGENT_ADDRESS")
    if executor_addr:
        ctx.storage.set("executor_agent_address", executor_addr)
    
    ctx.logger.info("MeTTa portfolio knowledge graph initialized")

if __name__ == "__main__":
    agent.run()
