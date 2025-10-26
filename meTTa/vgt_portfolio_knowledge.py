"""
MeTTa Knowledge Graph for Portfolio Management
Defines constraints, optimization rules, and risk parameters
"""

from hyperon import MeTTa, E, S, ValueAtom

def initialize_portfolio_knowledge(metta: MeTTa):
    """Initialize portfolio management knowledge graph"""
    
    # ===== POSITION CONSTRAINTS =====
    
    # Maximum single position sizes (percentage)
    metta.space().add_atom(E(S("max_position"), S("gold"), ValueAtom("0.50")))
    metta.space().add_atom(E(S("max_position"), S("silver"), ValueAtom("0.35")))
    metta.space().add_atom(E(S("max_position"), S("oil"), ValueAtom("0.40")))
    metta.space().add_atom(E(S("max_position"), S("cash"), ValueAtom("0.30")))
    
    # Minimum position sizes
    metta.space().add_atom(E(S("min_position"), S("gold"), ValueAtom("0.20")))
    metta.space().add_atom(E(S("min_position"), S("silver"), ValueAtom("0.10")))
    metta.space().add_atom(E(S("min_position"), S("oil"), ValueAtom("0.10")))
    metta.space().add_atom(E(S("min_position"), S("cash"), ValueAtom("0.10")))
    
    # ===== RISK RULES =====
    
    # Risk levels by asset
    metta.space().add_atom(E(S("risk_level"), S("gold"), ValueAtom("low")))
    metta.space().add_atom(E(S("risk_level"), S("silver"), ValueAtom("medium")))
    metta.space().add_atom(E(S("risk_level"), S("oil"), ValueAtom("high")))
    metta.space().add_atom(E(S("risk_level"), S("cash"), ValueAtom("none")))
    
    # Risk scores (for portfolio risk calculation)
    metta.space().add_atom(E(S("risk_score"), S("gold"), ValueAtom("2")))
    metta.space().add_atom(E(S("risk_score"), S("silver"), ValueAtom("3")))
    metta.space().add_atom(E(S("risk_score"), S("oil"), ValueAtom("4")))
    metta.space().add_atom(E(S("risk_score"), S("cash"), ValueAtom("0")))
    
    # ===== REBALANCING RULES =====
    
    # Drift thresholds (percentage points)
    metta.space().add_atom(E(S("drift_threshold"), S("normal"), ValueAtom("0.03")))  # 3%
    metta.space().add_atom(E(S("drift_threshold"), S("high_volatility"), ValueAtom("0.05")))  # 5%
    metta.space().add_atom(E(S("drift_threshold"), S("inflationary"), ValueAtom("0.03")))
    
    # Rebalancing frequency limits (minimum hours between rebalances)
    metta.space().add_atom(E(S("min_rebalance_interval"), S("hours"), ValueAtom("6")))
    metta.space().add_atom(E(S("max_daily_rebalances"), S("count"), ValueAtom("4")))
    
    # ===== COST ESTIMATION RULES =====
    
    # Gas cost per asset operation (USD)
    metta.space().add_atom(E(S("gas_cost"), S("open_position"), ValueAtom("0.50")))
    metta.space().add_atom(E(S("gas_cost"), S("close_position"), ValueAtom("0.50")))
    metta.space().add_atom(E(S("gas_cost"), S("adjust_position"), ValueAtom("0.30")))
    
    # Slippage estimates (percentage)
    metta.space().add_atom(E(S("slippage_estimate"), S("gold"), ValueAtom("0.001")))  # 0.1%
    metta.space().add_atom(E(S("slippage_estimate"), S("silver"), ValueAtom("0.002")))  # 0.2%
    metta.space().add_atom(E(S("slippage_estimate"), S("oil"), ValueAtom("0.001")))  # 0.1%
    
    # ===== EXECUTION RULES =====
    
    # Maximum trade size as % of available liquidity
    metta.space().add_atom(E(S("max_trade_size"), S("percentage_of_liquidity"), ValueAtom("0.10")))
    
    # Minimum trade size (USD) - don't execute tiny adjustments
    metta.space().add_atom(E(S("min_trade_size"), S("usd"), ValueAtom("100")))
    
    # ===== SAFETY CONSTRAINTS =====
    
    # Total leverage limit
    metta.space().add_atom(E(S("max_leverage"), S("total"), ValueAtom("3.0")))
    
    # Minimum cash buffer (for redemptions)
    metta.space().add_atom(E(S("min_cash_buffer"), S("percentage"), ValueAtom("0.10")))
    
    # Maximum drawdown before emergency deleverage
    metta.space().add_atom(E(S("max_drawdown"), S("percentage"), ValueAtom("0.20")))
    
    # Health factor threshold (liquidation safety)
    metta.space().add_atom(E(S("min_health_factor"), S("ratio"), ValueAtom("1.5")))
