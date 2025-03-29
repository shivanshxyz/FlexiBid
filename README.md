# FlexiBid: Dynamic Market Making for Flaunch

FlexiBid enhances Flaunch's BidWall mechanism with volatility-responsive market making strategies, delivering superior price protection and capital efficiency for memecoins.



https://github.com/user-attachments/assets/d1ee917a-c5a7-4f5a-856f-25cf65eb0f19



## 🌟 Overview
FlexiBid transforms the static 1-tick-below market making approach of Flaunch's BidWall into a sophisticated, adaptive system that responds to market conditions in real-time. By measuring volatility and adjusting liquidity positions accordingly, FlexiBid provides:

Better price stability during high volatility
Improved capital efficiency during stable markets
Customizable strategies for different memecoin profiles
Seamless integration with existing Flaunch infrastructure

## ❓ The Problem
Flaunch's BidWall currently uses a static, one-size-fits-all approach that places liquidity exactly 1 tick below spot price. This presents several limitations:

- During high volatility, a narrow 1-tick position provides insufficient price protection
- During stable periods, capital is concentrated too narrowly, missing efficiency opportunities
- Different memecoins have unique volatility profiles but receive identical treatment
- Position rebalancing doesn't adapt to market conditions

## 🔍 The Solution
FlexiBid introduces a dynamic market making system that:
- Measures volatility in real-time
- Adjusts liquidity positions based on market conditions
- Provides customizable strategies for different memecoin profiles

## 📦 Architecture
FlexiBid consists of two main components:

- `DynamicBidWallStrategy.sol`: Handles volatility tracking and position calculation
- `DynamicBidWall.sol`: Extends Flaunch's BidWall to implement dynamic strategies






