/*     METHOD ID
       ----------------------------
       1: ACT/ACT      (aka Proporc.)
       2: ACT/365      (aka Proporc. 28-31/365)
       3: ACT/360      (aka Proporc. 28-31/360)
       4: 30/360       (aka Proporc. 30/360)
       5: 30/365       (aka Proporc. 30/365)
       6: 30/365-6     (aka Proporc. 30/365-6)
       7: COMPOUND     (aka Konformne)
*/
-- Example using the stored procedure
EXEC dbo.sp_CalcInterest
  @Method = '2',                    -- METHOD ID (1...7) OR NAME ('Proporc', '30/360', 'Compound' ...)
  @StartDate  = '2010-06-14',       -- 'YYYY-MM-DD'
  @EndDate  = '2030-05-01',         -- 'YYYY-MM-DD'
  @Principal  = 200000,             -- DECIMAL
  @RatePct  = 13,                   -- DECIMAL
  @isAnticipative = 0;              -- 0 (default), 1

-- Example using the table-valued function
SELECT *
FROM dbo.fn_CalcInterest(
  '2',                -- METHOD ID or NAME
  '2010-06-14',       -- Start Date
  '2030-05-01',       -- End Date
  200000,             -- Principal
  13,                 -- Rate %
  0                   -- IsAnticipative (0 or 1)
);
