/* =============================================================================
   sp_CalcInterest
   -----------------------------------------------------------------------------
   Generic interest calculator for SQL Server.

     Why:
     - Provides multiple day-count conventions and compound mode.
     - Centralizes validation and calculation in one procedure.

     Inputs:
     @Method         : NVARCHAR(50) | Interest method id (1–7) or alias (e.g., 'ACT/ACT', '30/360', 'COMPOUND')
     @StartDate      : DATE         | Start date (exclusive for ACT/ACT segment start)
     @EndDate        : DATE         | End date (inclusive)
     @Principal      : DECIMAL(19,2)| Principal amount (> 0)
     @RatePct        : DECIMAL(9,2) | Nominal annual interest rate in percent (0..100)
     @IsAnticipative : BIT          | 0 = normal, 1 = anticipative (back-calculates principal)

     Supported methods (Id → Name → Common Aliases):
     1 → ACT/ACT     → PROPORC, ACTUAL/ACTUAL
     2 → ACT/365     → PROPORC.28-31/365, ACT365
     3 → ACT/360     → PROPORC.28-31/360, ACT360
     4 → 30/360      → 30E/360, 30EU/360, PROPORC.30/360
     5 → 30/365      → PROPORC.30/365
     6 → 30/365-6    → PROPORC.30/365-6, 30/3656  (year-denominator varies by leap year)
     7 → COMPOUND    → KONFORMNE, CONFORMAL

     Output columns (Normal):
     Start Date | End Date | Days | Rate % | Method | Principal (initial) | Interest (normal) | New Balance

     Output columns (Anticipative):
     Start Date | End Date | Days | Rate % | Method | Principal (final) | Principal (anticip) | Interest (anticip)

     Notes:
     - No DB name assumptions; safe to run in any database.
     - Uses THROW for precise error codes/messages.
     - Rounds final monetary outputs to 2 decimals.

   Author: Gege Dobruna (ASEE by Asseco internship)
   ============================================================================= */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.sp_CalcInterest
(
    @Method         nvarchar(50),
    @StartDate      date,
    @EndDate        date,
    @Principal      decimal(19,2),
    @RatePct        decimal(9,2),
    @IsAnticipative bit = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF @IsAnticipative IS NULL SET @IsAnticipative = 0;

        -- 0) Method mapping & normalization
        IF @Method IS NULL OR LTRIM(RTRIM(@Method)) = ''
            THROW 52000, N'Method is required (1–7 or a known alias).', 1;

        DECLARE @MethodMap TABLE (Id int PRIMARY KEY, Name nvarchar(50));
        INSERT INTO @MethodMap (Id,Name) VALUES
            (1,N'ACT/ACT'),
            (2,N'ACT/365'),
            (3,N'ACT/360'),
            (4,N'30/360'),
            (5,N'30/365'),
            (6,N'30/365-6'),
            (7,N'COMPOUND');

        DECLARE @AliasMap TABLE (Alias nvarchar(50), Id int);
        INSERT INTO @AliasMap (Alias,Id) VALUES
            (N'PROPORC',1),(N'PROPORC.',1),(N'ACT/ACT',1),(N'ACTUAL/ACTUAL',1),
            (N'PROPORC.28-31/365',2),(N'ACT/365',2),(N'ACT365',2),
            (N'PROPORC.28-31/360',3),(N'ACT/360',3),(N'ACT360',3),
            (N'PROPORC.30/360',4),(N'30/360',4),(N'30E/360',4),(N'30EU/360',4),
            (N'PROPORC.30/365',5),(N'30/365',5),
            (N'PROPORC.30/365-6',6),(N'30/365-6',6),(N'30/3656',6),
            (N'KONFORMNE',7),(N'CONFORMAL',7),(N'COMPOUND',7);

        DECLARE @MethodId int = TRY_CONVERT(int, @Method);
        IF @MethodId IS NULL
        BEGIN
            DECLARE @AliasNorm nvarchar(50) = UPPER(REPLACE(@Method,' ', ''));
            SELECT TOP(1) @MethodId = Id FROM @AliasMap WHERE Alias = @AliasNorm;
        END

        IF @MethodId IS NULL OR @MethodId NOT IN (1,2,3,4,5,6,7)
            THROW 52001, N'Unknown interest method. Use 1–7 or a valid alias.', 1;

        DECLARE @MethodName nvarchar(50);
        SELECT @MethodName = Name FROM @MethodMap WHERE Id = @MethodId;

        -- 1) Input validation
        IF @StartDate IS NULL
            THROW 52002, N'StartDate is required (YYYY-MM-DD).', 1;
        IF @EndDate IS NULL
            THROW 52003, N'EndDate is required (YYYY-MM-DD).', 1;
        IF @EndDate <= @StartDate
            THROW 52006, N'EndDate must be strictly after StartDate.', 1;

        IF @Principal IS NULL
            THROW 52007, N'Principal is required.', 1;
        IF @Principal <= 0
            THROW 52008, N'Principal must be > 0.', 1;

        IF @RatePct IS NULL
            THROW 52009, N'RatePct is required.', 1;
        IF @RatePct < 0
            THROW 52010, N'RatePct must be >= 0.', 1;
        IF @RatePct > 100
            THROW 52011, N'RatePct must be less than or equal to 100.', 1;

        DECLARE @DaysActual int = DATEDIFF(day, @StartDate, @EndDate); -- excl start, incl end (date-only)
        IF @DaysActual > 36600
        BEGIN
            SELECT 52012 AS ErrCode, N'Duration too large (> 100 years). Check dates.' AS ErrText,
                   N'sp_CalcInterest' AS ErrProc, NULL AS ErrLine;
            RETURN;
        END

        DECLARE @RateDecimal decimal(38,18) = CONVERT(decimal(38,18), @RatePct) / 100.0;

        -- 2) Day-count preparations
        -- 2a) ACT/ACT fraction across year segments
        DECLARE @t_actact decimal(38,18) = 0.0;
        DECLARE @DaysActSegSum int = 0;
        DECLARE @yAA int = YEAR(@StartDate), @yEndAA int = YEAR(@EndDate);

        WHILE @yAA <= @yEndAA
        BEGIN
            DECLARE @segStartAA date =
                CASE WHEN @yAA = YEAR(@StartDate) THEN DATEADD(day,1,@StartDate) ELSE DATEFROMPARTS(@yAA,1,1) END;
            DECLARE @segEndAA date =
                CASE WHEN @yAA = YEAR(@EndDate) THEN @EndDate ELSE DATEFROMPARTS(@yAA,12,31) END;

            IF @segEndAA >= @segStartAA
            BEGIN
                DECLARE @daysAA int = DATEDIFF(day, @segStartAA, @segEndAA) + 1; -- inclusive
                DECLARE @denAA int =
                    CASE WHEN (@yAA % 400 = 0) OR (@yAA % 4 = 0 AND @yAA % 100 <> 0) THEN 366 ELSE 365 END;

                SET @t_actact      += CONVERT(decimal(38,18), @daysAA) / CONVERT(decimal(38,18), @denAA);
                SET @DaysActSegSum += @daysAA;
            END
            SET @yAA += 1;
        END

        -- 2b) 30/360 (European) day count
        DECLARE @Y1 int = YEAR(@StartDate), @M1 int = MONTH(@StartDate), @D1 int = DAY(@StartDate);
        DECLARE @Y2 int = YEAR(@EndDate),   @M2 int = MONTH(@EndDate),   @D2 int = DAY(@EndDate);

        DECLARE @LastFeb1 int = CASE WHEN (@Y1 % 400 = 0) OR (@Y1 % 4 = 0 AND @Y1 % 100 <> 0) THEN 29 ELSE 28 END;
        DECLARE @LastFeb2 int = CASE WHEN (@Y2 % 400 = 0) OR (@Y2 % 4 = 0 AND @Y2 % 100 <> 0) THEN 29 ELSE 28 END;

        DECLARE @D1_30 int = @D1, @D2_30 int = @D2;
        IF @M1 = 2 AND @D1 = @LastFeb1 SET @D1_30 = 30;
        IF @M2 = 2 AND @D2 = @LastFeb2 SET @D2_30 = 30;
        IF @D1_30 > 30 SET @D1_30 = 30;
        IF @D2_30 > 30 SET @D2_30 = 30;

        DECLARE @days_30_360 int =
            ((@Y2 - @Y1) * 360) + ((@M2 - @M1) * 30) + (@D2_30 - @D1_30);

        -- 2c) 30-grid (used for 30/365 and 30/365-6)
        DECLARE @D1e int = CASE WHEN @D1 > 30 THEN 30 ELSE @D1 END;
        DECLARE @D2e int = CASE WHEN @D2 > 30 THEN 30 ELSE @D2 END;
        DECLARE @days_30_grid int =
            ((@Y2 - @Y1) * 360) + ((@M2 - @M1) * 30) + (@D2e - @D1e);

        -- 3) Interest calculation
        DECLARE @InterestRaw decimal(19,8) = 0.0;
        DECLARE @Frac decimal(38,18) = NULL;

        -- Linear methods (1...5)
        IF      @MethodId = 1 SET @Frac = @t_actact;
        ELSE IF @MethodId = 2 SET @Frac = CONVERT(decimal(38,18), @DaysActual) / 365.0;
        ELSE IF @MethodId = 3 SET @Frac = CONVERT(decimal(38,18), @DaysActual) / 360.0;
        ELSE IF @MethodId = 4 SET @Frac = CONVERT(decimal(38,18), @days_30_360) / 360.0;
        ELSE IF @MethodId = 5 SET @Frac = CONVERT(decimal(38,18), @days_30_grid) / 365.0;

        IF @Frac IS NOT NULL
        BEGIN
            SET @InterestRaw = CONVERT(decimal(38,18), @Principal) * @RateDecimal * @Frac;
        END
        ELSE IF @MethodId = 6
        BEGIN
            -- 30/365-6: compute year-by-year with denominator = 365 or 366 depending on year
            DECLARE @sum306 decimal(38,18) = 0.0;
            DECLARE @yy306 int = YEAR(@StartDate), @yyEnd306 int = YEAR(@EndDate);

            WHILE @yy306 <= @yyEnd306
            BEGIN
                DECLARE @segStart306 date =
                    CASE WHEN @yy306 = YEAR(@StartDate) THEN @StartDate ELSE DATEFROMPARTS(@yy306,1,1) END;
                DECLARE @segEndEx306 date =
                    CASE WHEN @yy306 = YEAR(@EndDate) THEN @EndDate ELSE DATEFROMPARTS(@yy306+1,1,1) END;

                IF @segEndEx306 > @segStart306
                BEGIN
                    DECLARE @Y1s int = YEAR(@segStart306), @M1s int = MONTH(@segStart306), @D1s int = DAY(@segStart306);
                    DECLARE @Y2s int = YEAR(@segEndEx306), @M2s int = MONTH(@segEndEx306), @D2s int = DAY(@segEndEx306);

                    IF @D1s > 30 SET @D1s = 30;
                    IF @D2s > 30 SET @D2s = 30;

                    DECLARE @Days30s int = ((@Y2s - @Y1s)*360) + ((@M2s - @M1s)*30) + (@D2s - @D1s);
                    DECLARE @Den306 int =
                        CASE WHEN (@yy306 % 400 = 0) OR (@yy306 % 4 = 0 AND @yy306 % 100 <> 0) THEN 366 ELSE 365 END;

                    SET @sum306 += CONVERT(decimal(38,18), @Principal) * @RateDecimal
                                   * ( CONVERT(decimal(38,18), @Days30s) / CONVERT(decimal(38,18), @Den306) );
                END
                SET @yy306 += 1;
            END

            SET @InterestRaw = CONVERT(decimal(19,8), @sum306);
        END
        ELSE IF @MethodId = 7  -- COMPOUND (using ACT/ACT fraction as exponent)
        BEGIN
            DECLARE @factor float = POWER(1.0 + (CONVERT(float,@RatePct)/100.0), CONVERT(float,@t_actact));
            SET @InterestRaw = CONVERT(decimal(38,18), @Principal) * CONVERT(decimal(38,18), @factor - 1.0);
        END

        -- 4) “Days” value for output (to match numerator concept per method)
        DECLARE @DaysOut int =
            CASE
                WHEN @MethodId IN (1,7) THEN @DaysActSegSum
                WHEN @MethodId IN (2,3) THEN @DaysActual
                WHEN @MethodId = 4       THEN @days_30_360
                WHEN @MethodId = 5       THEN @days_30_grid
                WHEN @MethodId = 6       THEN 0  -- recomputed below per-year 30-grid
            END;

        IF @MethodId = 6
        BEGIN
            DECLARE @yyR int = YEAR(@StartDate), @yyREnd int = YEAR(@EndDate), @acc int = 0;
            WHILE @yyR <= @yyREnd
            BEGIN
                DECLARE @s date = CASE WHEN @yyR = YEAR(@StartDate) THEN @StartDate ELSE DATEFROMPARTS(@yyR,1,1) END;
                DECLARE @e date = CASE WHEN @yyR = YEAR(@EndDate) THEN @EndDate ELSE DATEFROMPARTS(@yyR+1,1,1) END;
                IF @e > @s
                BEGIN
                    DECLARE @ys int = YEAR(@s), @ms int = MONTH(@s), @ds int = DAY(@s);
                    DECLARE @ye int = YEAR(@e), @me int = MONTH(@e), @de int = DAY(@e);
                    IF @ds > 30 SET @ds = 30;
                    IF @de > 30 SET @de = 30;
                    SET @acc += ((@ye-@ys)*360) + ((@me-@ms)*30) + (@de-@ds);
                END
                SET @yyR += 1;
            END
            SET @DaysOut = @acc;
        END

        -- 5) Output: normal vs anticipative
        IF @IsAnticipative = 1
        BEGIN
            DECLARE @rateFactor decimal(38,18) = CONVERT(decimal(38,18), @InterestRaw) / CONVERT(decimal(38,18), @Principal);
            DECLARE @PrincipalAnticip decimal(19,2) = ROUND(@Principal / (1 + @rateFactor), 2);
            DECLARE @InterestAnticip  decimal(19,2) = @Principal - @PrincipalAnticip;

            SELECT
              [Start Date]                 = @StartDate,
              [End Date]                   = @EndDate,
              [Days]                       = @DaysOut,
              [Rate %]                     = @RatePct,
              [Method]                     = @MethodName,
              [Principal (final)]          = @Principal,
              [Principal (anticip)]        = @PrincipalAnticip,
              [Interest (anticip)]         = @InterestAnticip;
        END
        ELSE
        BEGIN
            DECLARE @InterestRounded decimal(19,2) = ROUND(@InterestRaw, 2);

            SELECT
              [Start Date]                 = @StartDate,
              [End Date]                   = @EndDate,
              [Days]                       = @DaysOut,
              [Rate %]                     = @RatePct,
              [Method]                     = @MethodName,
              [Principal (initial)]        = @Principal,
              [Interest (normal)]          = @InterestRounded,
              [New Balance]                = @Principal + @InterestRounded;
        END
    END TRY
    BEGIN CATCH
        DECLARE @ErrMsg  nvarchar(4000) = ERROR_MESSAGE();
        DECLARE @ErrNum  int            = ERROR_NUMBER();
        DECLARE @ErrState tinyint       = ERROR_STATE();

        -- Convert/overflow/type issues
        IF @ErrNum BETWEEN 8114 AND 8624 OR @ErrNum IN (245,248,295,8115)
            THROW 52999, N'Calculation/convert error. Check inputs (types, ranges).', 1;
        ELSE
            THROW @ErrNum, @ErrMsg, @ErrState;
    END CATCH
END
GO
