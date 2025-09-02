# SQL Interest Calculator

A collection of SQL Server functions, a stored procedure, and a **table-valued function** for **general interest calculation**.  
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
- Two ways to use:
  - **Stored procedure** (`sp_CalcInterest`) → returns results in a queryable resultset  
  - **Table-valued function** (`fn_CalcInterest`) → can be embedded directly in `SELECT` queries

## ⚙️ Installation (simple)
1) Open your target database in SSMS (or any SQL client).  
2) Run the scripts:  
   - `sql/procedures/sp_CalcInterest.sql` (procedure)  
   - `sql/functions/fn_CalcInterest.sql` (table-valued function)  
3) That’s it — both are now available in the **current** database.

## ▶️ Run Examples
- **Stored Procedure**

```sql
EXEC dbo.sp_CalcInterest
  @Method = 'ACT/ACT',
  @StartDate = '2023-01-01',
  @EndDate   = '2023-12-31',
  @Principal = 10000,
  @RatePct   = 5,
  @IsAnticipative = 0;
```

- **Table-Valued Function**

```sql
SELECT *
FROM dbo.fn_CalcInterest(
  'ACT/ACT',
  '2023-01-01',
  '2023-12-31',
  10000,
  5,
  0
);
```

## 📤 Output Columns
- **Normal**:

| Start Date | End Date   | Days | Rate % | Method  | Principal (initial) | Interest (normal) | New Balance |
|------------|------------|------|--------|---------|----------------------|-------------------|-------------|
| 2023-01-01 | 2023-12-31 | 364  | 5.00   | ACT/365 | 10000.00             | 498.63            | 10498.63    |

- **Anticipative**: 

| Start Date | End Date   | Days | Rate % | Method  | Principal (final) | Principal (anticip) | Interest (anticip) |
|------------|------------|------|--------|---------|-------------------|---------------------|--------------------|
| 2023-07-01 | 2023-08-15 | 44   | 11.00  | 30/360  | 250000.00         | 239103.45           | 10896.55           |

## 📚 Notes
- This repository was created as part of my **internship at ASEE by Asseco**.  
- It is intended for educational/demo purposes and may not reflect production-grade financial software.  

---
👤 **Author:** Gegë Dobruna (Intern at ASEE by Asseco)  
📅 **Year:** 2025
