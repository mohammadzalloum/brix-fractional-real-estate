# BRIX — Truffle + Next.js Frontend

![WhatsApp Image 2025-12-18 at 5 49 31 PM](https://github.com/user-attachments/assets/a2e34687-425e-4a21-a193-ab5fa4c408ba)


BRIX is a Web3 prototype for **fractional real estate investing**, built with **Solidity + Truffle** and a **Next.js** frontend.  
It includes a full local development workflow using **Ganache**, with automatic syncing of deployed contract addresses to the frontend.

---

## Key Features

- **Solidity smart contracts** managed with Truffle
- **Local blockchain** development workflow (Ganache)
- **Next.js frontend** integrated with deployed contract addresses
- **Automated deployments config** generated at:
  `frontend/src/config/deployments/local.json`
- Truffle **migrations** and **tests** included

> Note: This repository is currently designed for local development and experimentation.

---

## Tech Stack

- **Solidity** (Smart Contracts)
- **Truffle** (Compile / Migrate / Test)
- **Ganache** (Local Ethereum network)
- **Next.js** (Frontend)

---

## Project Structure

- `contracts/` — Solidity smart contracts  
- `migrations/` — Truffle deployment scripts  
- `test/` — Truffle tests  
- `truffle-config.js` — Truffle configuration  
- `frontend/` — Next.js web app (UI)

---

## Prerequisites

- Node.js (recommended: LTS)
- npm
- Git
- (Optional) MetaMask for interacting with the local chain

---

## Quick Start (Local)

### 1) Install dependencies & start local chain (Ganache)
From the repository root:

```bash
npm install
npm run chain
