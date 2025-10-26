"""
Market Analysis using MeTTa Knowledge Graph
Performs reasoning over market data to determine regimes and preferences
"""

from hyperon import MeTTa

class MarketAnalyzer:
    def __init__(self, metta_instance: MeTTa):
        self.metta = metta_instance
    
    def determine_market_regime(self, cpi: float, interest_rate: float, volatility: float) -> str:
        """Determine current market regime based on indicators"""
        
        # High volatility regime takes precedence
        if volatility > 25:
            return "high_volatility"
        
        # Check for stagflation (high inflation + low growth)
        # For hackathon, simplified: just check if CPI > 4%
        if cpi > 4.0:
            return "stagflation"
        
        # Inflationary regime
        if cpi > 3.0 and interest_rate < 6.0:
            return "inflationary"
        
        # Deflationary regime
        if cpi < 2.0:
            return "deflationary"
        
        # Default to normal
        return "normal"
    
    def get_regime_preferences(self, regime: str) -> dict:
        """Query MeTTa for asset preferences in given regime"""
        preferences = {}
        
        for asset in ["gold", "silver", "oil"]:
            query_str = f'!(match &self (regime_preference {regime} {asset} $pref) $pref)'
            results = self.metta.run(query_str)
            
            if results and len(results) > 0 and len(results[0]) > 0:
                pref_value = results[0][0].get_object().value
                preferences[asset] = pref_value
            else:
                preferences[asset] = "medium"  # Default
        
        return preferences
    
    def calculate_target_weights(self, regime: str, current_weights: dict, 
                                 cpi: float, volatility: float) -> dict:
        """Calculate target weights based on regime and current state"""
        
        # Get baseline weights for regime
        target_weights = {}
        
        # Map regime to baseline allocation type
        allocation_type = regime
        if regime == "normal":
            allocation_type = "normal"
        elif regime in ["inflationary", "stagflation"]:
            allocation_type = "inflationary"
        elif regime == "high_volatility":
            allocation_type = "defensive"
        
        # Query baseline weights
        for asset in ["gold", "silver", "oil", "cash"]:
            query_str = f'!(match &self (baseline_weight {allocation_type} {asset} $weight) $weight)'
            results = self.metta.run(query_str)
            
            if results and len(results) > 0 and len(results[0]) > 0:
                weight_str = results[0][0].get_object().value
                target_weights[asset] = float(weight_str)
            else:
                # Fallback to normal allocation
                defaults = {"gold": 0.40, "silver": 0.20, "oil": 0.25, "cash": 0.15}
                target_weights[asset] = defaults.get(asset, 0.15)
        
        # Apply volatility adjustment
        if volatility > 30:
            # Very high volatility - move more to safety
            target_weights["gold"] += 0.05
            target_weights["cash"] += 0.05
            target_weights["silver"] -= 0.05
            target_weights["oil"] -= 0.05
        
        # Normalize to ensure sum = 1.0
        total = sum(target_weights.values())
        target_weights = {k: v/total for k, v in target_weights.items()}
        
        return target_weights
    
    def explain_reasoning(self, regime: str, adjustments: dict, 
                         cpi: float, interest_rate: float, volatility: float) -> str:
        """Generate human-readable explanation of reasoning"""
        
        explanation = f"Market Regime: {regime.replace('_', ' ').title()}\n\n"
        explanation += f"Economic Indicators:\n"
        explanation += f"- CPI Inflation: {cpi:.1f}%\n"
        explanation += f"- Interest Rate: {interest_rate:.1f}%\n"
        explanation += f"- VIX Volatility: {volatility:.1f}\n\n"
        
        explanation += "Reasoning:\n"
        
        if regime == "inflationary":
            explanation += "High inflation environment detected. "
            explanation += "Gold and silver historically protect purchasing power during inflation. "
            explanation += "Increasing precious metals allocation.\n"
        elif regime == "high_volatility":
            explanation += "Elevated market volatility detected. "
            explanation += "Flight to safety warranted. "
            explanation += "Increasing gold (safe haven) and cash, reducing cyclical exposure.\n"
        elif regime == "stagflation":
            explanation += "Stagflation regime: high inflation with weak growth. "
            explanation += "Gold performs exceptionally well in this environment. "
            explanation += "Maximizing gold allocation.\n"
        elif regime == "deflationary":
            explanation += "Deflationary pressures detected. "
            explanation += "Commodities underperform in deflation. "
            explanation += "Increasing cash buffer, reducing commodity exposure.\n"
        else:
            explanation += "Balanced market conditions. "
            explanation += "Maintaining diversified allocation across gold, silver, and oil.\n"
        
        explanation += "\nRecommended Adjustments:\n"
        for asset, adjustment in adjustments.items():
            if abs(adjustment) > 0.5:
                direction = "Increase" if adjustment > 0 else "Decrease"
                explanation += f"- {asset.title()}: {direction} by {abs(adjustment):.1f}%\n"
        
        return explanation
    
    def calculate_confidence(self, volatility: float, cpi: float) -> float:
        """Calculate confidence score for analysis (0-1)"""
        
        # Higher confidence when signals are clear
        confidence = 0.8  # Base confidence
        
        # Reduce confidence in very high volatility (unclear signals)
        if volatility > 35:
            confidence -= 0.2
        elif volatility > 25:
            confidence -= 0.1
        
        # Increase confidence when inflation signal is strong
        if cpi > 4.0 or cpi < 1.5:
            confidence += 0.1
        
        # Clamp between 0.4 and 0.95
        return max(0.4, min(0.95, confidence))
