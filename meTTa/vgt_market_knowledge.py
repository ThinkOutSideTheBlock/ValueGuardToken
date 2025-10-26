"""
MeTTa Knowledge Graph for Market Relationships
Defines economic relationships, correlations, and market regime rules
"""

from hyperon import MeTTa, E, S, ValueAtom

def initialize_market_knowledge(metta: MeTTa):
    """Initialize market intelligence knowledge graph"""
    
    # ===== INFLATION & INTEREST RATE RULES =====
    
    # Inflation rising → Gold bullish
    metta.space().add_atom(E(S("inflation_impact"), S("rising"), S("gold"), S("bullish")))
    metta.space().add_atom(E(S("inflation_impact"), S("rising"), S("silver"), S("bullish")))
    metta.space().add_atom(E(S("inflation_impact"), S("rising"), S("oil"), S("neutral")))
    
    # Inflation falling → Gold bearish
    metta.space().add_atom(E(S("inflation_impact"), S("falling"), S("gold"), S("bearish")))
    metta.space().add_atom(E(S("inflation_impact"), S("falling"), S("silver"), S("bearish")))
    metta.space().add_atom(E(S("inflation_impact"), S("falling"), S("oil"), S("bearish")))
    
    # Interest rates high → Gold bearish (opportunity cost)
    metta.space().add_atom(E(S("interest_rate_impact"), S("high"), S("gold"), S("bearish")))
    metta.space().add_atom(E(S("interest_rate_impact"), S("high"), S("silver"), S("bearish")))
    metta.space().add_atom(E(S("interest_rate_impact"), S("high"), S("oil"), S("neutral")))
    
    # Interest rates low → Gold bullish
    metta.space().add_atom(E(S("interest_rate_impact"), S("low"), S("gold"), S("bullish")))
    metta.space().add_atom(E(S("interest_rate_impact"), S("low"), S("silver"), S("bullish")))
    metta.space().add_atom(E(S("interest_rate_impact"), S("low"), S("oil"), S("bullish")))
    
    # ===== VOLATILITY RULES =====
    
    # High volatility → Reduce overall leverage, increase safe haven (gold)
    metta.space().add_atom(E(S("volatility_impact"), S("high"), S("gold"), S("increase")))
    metta.space().add_atom(E(S("volatility_impact"), S("high"), S("silver"), S("decrease")))
    metta.space().add_atom(E(S("volatility_impact"), S("high"), S("oil"), S("decrease")))
    metta.space().add_atom(E(S("volatility_impact"), S("high"), S("cash"), S("increase")))
    
    # Low volatility → Can increase risk assets
    metta.space().add_atom(E(S("volatility_impact"), S("low"), S("gold"), S("neutral")))
    metta.space().add_atom(E(S("volatility_impact"), S("low"), S("silver"), S("increase")))
    metta.space().add_atom(E(S("volatility_impact"), S("low"), S("oil"), S("increase")))
    
    # ===== GEOPOLITICAL RULES =====
    
    # War/conflict → Gold and oil bullish
    metta.space().add_atom(E(S("geopolitical_impact"), S("war"), S("gold"), S("bullish")))
    metta.space().add_atom(E(S("geopolitical_impact"), S("war"), S("oil"), S("bullish")))
    metta.space().add_atom(E(S("geopolitical_impact"), S("war"), S("silver"), S("neutral")))
    
    # Peace/stability → Risk assets can increase
    metta.space().add_atom(E(S("geopolitical_impact"), S("peace"), S("gold"), S("neutral")))
    metta.space().add_atom(E(S("geopolitical_impact"), S("peace"), S("oil"), S("neutral")))
    metta.space().add_atom(E(S("geopolitical_impact"), S("peace"), S("silver"), S("bullish")))
    
    # ===== ASSET CORRELATIONS =====
    
    # Gold and silver are positively correlated (0.7)
    metta.space().add_atom(E(S("correlation"), S("gold"), S("silver"), ValueAtom("0.7")))
    metta.space().add_atom(E(S("correlation"), S("silver"), S("gold"), ValueAtom("0.7")))
    
    # Gold and oil are weakly correlated (0.3)
    metta.space().add_atom(E(S("correlation"), S("gold"), S("oil"), ValueAtom("0.3")))
    metta.space().add_atom(E(S("correlation"), S("oil"), S("gold"), ValueAtom("0.3")))
    
    # Silver and oil are moderately correlated (0.5)
    metta.space().add_atom(E(S("correlation"), S("silver"), S("oil"), ValueAtom("0.5")))
    metta.space().add_atom(E(S("correlation"), S("oil"), S("silver"), ValueAtom("0.5")))
    
    # ===== MARKET REGIME DEFINITIONS =====
    
    # Inflationary regime: CPI > 3%, interest rates < 6%
    metta.space().add_atom(E(S("market_regime"), S("inflationary"), 
                            ValueAtom("CPI > 3% and interest_rate < 6%")))
    
    # Deflationary regime: CPI < 2%, interest rates any
    metta.space().add_atom(E(S("market_regime"), S("deflationary"), 
                            ValueAtom("CPI < 2%")))
    
    # High volatility regime: VIX > 25
    metta.space().add_atom(E(S("market_regime"), S("high_volatility"), 
                            ValueAtom("VIX > 25")))
    
    # Stagflation: High inflation + low growth
    metta.space().add_atom(E(S("market_regime"), S("stagflation"), 
                            ValueAtom("CPI > 4% and growth < 1%")))
    
    # ===== REGIME-SPECIFIC ASSET PREFERENCES =====
    
    # Inflationary regime preferences
    metta.space().add_atom(E(S("regime_preference"), S("inflationary"), S("gold"), ValueAtom("high")))
    metta.space().add_atom(E(S("regime_preference"), S("inflationary"), S("silver"), ValueAtom("medium")))
    metta.space().add_atom(E(S("regime_preference"), S("inflationary"), S("oil"), ValueAtom("medium")))
    
    # Deflationary regime preferences
    metta.space().add_atom(E(S("regime_preference"), S("deflationary"), S("gold"), ValueAtom("low")))
    metta.space().add_atom(E(S("regime_preference"), S("deflationary"), S("silver"), ValueAtom("low")))
    metta.space().add_atom(E(S("regime_preference"), S("deflationary"), S("oil"), ValueAtom("low")))
    metta.space().add_atom(E(S("regime_preference"), S("deflationary"), S("cash"), ValueAtom("high")))
    
    # High volatility regime preferences (flight to safety)
    metta.space().add_atom(E(S("regime_preference"), S("high_volatility"), S("gold"), ValueAtom("very_high")))
    metta.space().add_atom(E(S("regime_preference"), S("high_volatility"), S("silver"), ValueAtom("low")))
    metta.space().add_atom(E(S("regime_preference"), S("high_volatility"), S("oil"), ValueAtom("low")))
    metta.space().add_atom(E(S("regime_preference"), S("high_volatility"), S("cash"), ValueAtom("high")))
    
    # Stagflation regime preferences (gold thrives)
    metta.space().add_atom(E(S("regime_preference"), S("stagflation"), S("gold"), ValueAtom("very_high")))
    metta.space().add_atom(E(S("regime_preference"), S("stagflation"), S("silver"), ValueAtom("medium")))
    metta.space().add_atom(E(S("regime_preference"), S("stagflation"), S("oil"), ValueAtom("low")))
    
    # ===== TARGET WEIGHT BASELINES =====
    
    # Normal balanced allocation
    metta.space().add_atom(E(S("baseline_weight"), S("normal"), S("gold"), ValueAtom("0.40")))
    metta.space().add_atom(E(S("baseline_weight"), S("normal"), S("silver"), ValueAtom("0.20")))
    metta.space().add_atom(E(S("baseline_weight"), S("normal"), S("oil"), ValueAtom("0.25")))
    metta.space().add_atom(E(S("baseline_weight"), S("normal"), S("cash"), ValueAtom("0.15")))
    
    # Inflationary allocation (more gold)
    metta.space().add_atom(E(S("baseline_weight"), S("inflationary"), S("gold"), ValueAtom("0.50")))
    metta.space().add_atom(E(S("baseline_weight"), S("inflationary"), S("silver"), ValueAtom("0.20")))
    metta.space().add_atom(E(S("baseline_weight"), S("inflationary"), S("oil"), ValueAtom("0.20")))
    metta.space().add_atom(E(S("baseline_weight"), S("inflationary"), S("cash"), ValueAtom("0.10")))
    
    # Defensive allocation (high volatility)
    metta.space().add_atom(E(S("baseline_weight"), S("defensive"), S("gold"), ValueAtom("0.45")))
    metta.space().add_atom(E(S("baseline_weight"), S("defensive"), S("silver"), ValueAtom("0.15")))
    metta.space().add_atom(E(S("baseline_weight"), S("defensive"), S("oil"), ValueAtom("0.15")))
    metta.space().add_atom(E(S("baseline_weight"), S("defensive"), S("cash"), ValueAtom("0.25")))
