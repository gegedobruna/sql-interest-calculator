# SQL Interest Calculator

A collection of SQL Server functions and a stored procedure for **general interest calculation**.  
Developed during my internship at **ASEE by Asseco** as part of a banking system environment.

## 📌 Overview
This project provides reusable SQL utilities to calculate financial interest between two dates with flexible parameters.  
It is designed for banking and financial use cases, but the logic is generic enough to apply in other domains.

## 🚀 Features
- Multiple interest calculation methods:
  - Proporc. (Proportional)
  - 30/360
  - 28–31/365
  - 30/365-6
  - Compound
  - Anticipative options
- Validates input dates and parameters
- Returns precise decimal values with rounding
- Centralized stored procedure (`sp_CalcInterest`) to call any method

## ⚙️ Parameters

The main stored procedure:

```sql
EXEC dbo.sp_CalcInterest
    @Method   = 'compound',      -- method name (string)
    @Date1    = '2023-12-01',    -- start date
    @Date2    = '2033-12-01',    -- end date
    @Shuma    = 300000,          -- principal amount
    @RateP    = 11,              -- interest rate (percent)
    @Anticip  = 0;               -- anticipation flag (0 or 1)
```

### Arguments
- `@Method` → interest calculation method (see list above)
- `@Date1` → starting date
- `@Date2` → ending date
- `@Shuma` → principal amount (decimal)
- `@RateP` → interest rate as a percentage (decimal)
- `@Anticip` → anticipation mode (bit, default 0)

## 📊 Example Output
| Data Prej | Data Deri   | Ditet | Norma | Metoda   | Shuma (Vlera fillestare) | Interesi (normal) | Gjendja e re |
|-----------|------------|-------|-------|----------|---------------------------|-------------------|--------------|
| 2023-07-15 | 2027-12-12 | 1611  | 3.00  | proporc  | 10000.00                  | 1323.29           | 11323.29     |

## 🛠️ Structure
- `fn_*` → calculation functions (one per method)
- `sp_CalcInterest` → stored procedure wrapper that selects the right function
- `test_scripts.sql` → example executions and validations

## 📚 Notes
- This repository was created as part of my **internship at ASEE / Asseco**.  
- It is intended for educational/demo purposes and may not reflect production-grade financial software.  

---
👤 **Author:** Gegë Dobruna (Intern at ASEE by Asseco)  
📅 **Year:** 2025
