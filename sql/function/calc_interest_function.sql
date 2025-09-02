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

-- select * from dbo.calcinterest(1,'2020.5.12','2026.5.12',10000,4,0)

CREATE OR ALTER FUNCTION dbo.fn_CalcInterest
(
    @Method   nvarchar(50),    
    @Date1    date,
    @Date2    date,
    @Shuma    decimal(19,2),
    @RateP    decimal(9,2),
    @Anticip  bit = 0
)
RETURNS @Result TABLE
(
    -- Error/status first (filled on invalid input; NULL on success)
    ErrCode int            NULL,
    ErrText nvarchar(4000) NULL,

    -- Common outputs (dates formatted as requested)
    [Data Prej]                char(10)      NULL,
    [Data Deri]                char(10)      NULL,
    [Ditet]                    int           NULL,
    [Norma]                    decimal(9,2)  NULL,
    [Metoda]                   nvarchar(50)  NULL,

    -- Normal-mode outputs:
    [Shuma (Vlera fillestare)] decimal(19,2) NULL,
    [Interesi]                 decimal(19,2) NULL,
    [Gjendja e re]             decimal(19,2) NULL,

    -- Anticipative-mode outputs:
    [Shuma (Vlera finale)]     decimal(19,2) NULL,
    [Gj.Paraprake (anticip)]   decimal(19,2) NULL,
    [Interesi (anticip)]       decimal(19,2) NULL
)
AS
BEGIN
    /* ---------- 0) VALIDATION (return error row instead of THROW) ---------- */
    IF @Method IS NULL OR LTRIM(RTRIM(@Method)) = ''
    BEGIN INSERT INTO @Result(ErrCode,ErrText) VALUES (52000,N'Method is required (1–7 or alias).'); RETURN; END;
    IF @Date1 IS NULL
    BEGIN INSERT INTO @Result(ErrCode,ErrText) VALUES (52002,N'Date1 is required (YYYY-MM-DD).'); RETURN; END;
    IF @Date2 IS NULL
    BEGIN INSERT INTO @Result(ErrCode,ErrText) VALUES (52003,N'Date2 is required (YYYY-MM-DD).'); RETURN; END;
    IF @Date2 <= @Date1
    BEGIN INSERT INTO @Result(ErrCode,ErrText) VALUES (52006,N'Date2 must be strictly after Date1.'); RETURN; END;
    IF @Shuma IS NULL OR @Shuma <= 0
    BEGIN INSERT INTO @Result(ErrCode,ErrText) VALUES (52008,N'Shuma (principal) must be > 0.'); RETURN; END;
    IF @RateP IS NULL
    BEGIN INSERT INTO @Result(ErrCode,ErrText) VALUES (52009,N'RateP is required.'); RETURN; END;
    IF @RateP < 0
    BEGIN INSERT INTO @Result(ErrCode,ErrText) VALUES (52010,N'RateP must be >= 0.'); RETURN; END;
    IF @RateP > 100
    BEGIN INSERT INTO @Result(ErrCode,ErrText) VALUES (52011,N'RateP must be less than 100.'); RETURN; END;

    DECLARE @DaysAll int = DATEDIFF(day, @Date1, @Date2); -- excl start, incl end via later +1s
    IF @DaysAll > 36600
    BEGIN INSERT INTO @Result(ErrCode,ErrText) VALUES (52012,N'Duration too large (> 100 years). Check dates.'); RETURN; END;

    /* ---------- 1) METHOD MAPS ---------- */
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
        DECLARE @AliasNorm nvarchar(50) = UPPER(REPLACE(@Method,' ',''));
        SELECT TOP(1) @MethodId = Id FROM @AliasMap WHERE Alias = @AliasNorm;
    END
    IF @MethodId IS NULL OR @MethodId NOT IN (1,2,3,4,5,6,7)
    BEGIN INSERT INTO @Result(ErrCode,ErrText) VALUES (52001,N'Unknown interest method. Use 1–7 or a valid alias.'); RETURN; END;

    DECLARE @MethodName nvarchar(50);
    SELECT @MethodName = Name FROM @MethodMap WHERE Id = @MethodId;

    DECLARE @RateDec decimal(38,18) = CONVERT(decimal(38,18), @RateP) / 100.0;

    /* ---------- 2) DAY-COUNT INGREDIENTS ---------- */

    -- 2a) ACT/ACT fraction (per-year to handle leap years)
    DECLARE @t_actact decimal(38,18) = 0.0;
    DECLARE @DaysActSegSum int = 0;
    DECLARE @yAA int = YEAR(@Date1), @yEndAA int = YEAR(@Date2);

    WHILE @yAA <= @yEndAA
    BEGIN
        DECLARE @segStartAA date =
            CASE WHEN @yAA = YEAR(@Date1) THEN DATEADD(day,1,@Date1) ELSE DATEFROMPARTS(@yAA,1,1) END;
        DECLARE @segEndAA date =
            CASE WHEN @yAA = YEAR(@Date2) THEN @Date2 ELSE DATEFROMPARTS(@yAA,12,31) END;

        IF @segEndAA >= @segStartAA
        BEGIN
            DECLARE @daysAA int = DATEDIFF(day, @segStartAA, @segEndAA) + 1; -- inclusive
            DECLARE @denAA int =
                CASE WHEN (@yAA % 400 = 0) OR (@yAA % 4 = 0 AND @yAA % 100 <> 0) THEN 366 ELSE 365 END;

            SET @t_actact     += CONVERT(decimal(38,18), @daysAA) / CONVERT(decimal(38,18), @denAA);
            SET @DaysActSegSum += @daysAA;
        END
        SET @yAA += 1;
    END

    -- 2b) 30/360 with Feb-end adjustments
    DECLARE @Y1 int = YEAR(@Date1), @M1 int = MONTH(@Date1), @D1 int = DAY(@Date1);
    DECLARE @Y2 int = YEAR(@Date2), @M2 int = MONTH(@Date2), @D2 int = DAY(@Date2);

    DECLARE @LastFeb1 int = CASE WHEN (@Y1 % 400 = 0) OR (@Y1 % 4 = 0 AND @Y1 % 100 <> 0) THEN 29 ELSE 28 END;
    DECLARE @LastFeb2 int = CASE WHEN (@Y2 % 400 = 0) OR (@Y2 % 4 = 0 AND @Y2 % 100 <> 0) THEN 29 ELSE 28 END;

    DECLARE @D1_30 int = @D1, @D2_30 int = @D2;
    IF @M1 = 2 AND @D1 = @LastFeb1 SET @D1_30 = 30;
    IF @M2 = 2 AND @D2 = @LastFeb2 SET @D2_30 = 30;
    IF @D1_30 > 30 SET @D1_30 = 30;
    IF @D2_30 > 30 SET @D2_30 = 30;

    DECLARE @days_30_360 int =
        ((@Y2 - @Y1) * 360) + ((@M2 - @M1) * 30) + (@D2_30 - @D1_30);

    -- 2c) 30-grid (for 30/365 and 30/365-6)
    DECLARE @D1e int = CASE WHEN @D1 > 30 THEN 30 ELSE @D1 END;
    DECLARE @D2e int = CASE WHEN @D2 > 30 THEN 30 ELSE @D2 END;
    DECLARE @days_30_grid int =
        ((@Y2 - @Y1) * 360) + ((@M2 - @M1) * 30) + (@D2e - @D1e);

    /* ---------- 3) INTEREST CALCULATION ---------- */
    DECLARE @InterestNormal decimal(19,8) = 0.0;
    DECLARE @Frac decimal(38,18) = NULL;

    IF      @MethodId = 1 SET @Frac = @t_actact;                                   -- ACT/ACT
    ELSE IF @MethodId = 2 SET @Frac = CONVERT(decimal(38,18), @DaysAll)     / 365.0;-- ACT/365
    ELSE IF @MethodId = 3 SET @Frac = CONVERT(decimal(38,18), @DaysAll)     / 360.0;-- ACT/360
    ELSE IF @MethodId = 4 SET @Frac = CONVERT(decimal(38,18), @days_30_360) / 360.0;-- 30/360
    ELSE IF @MethodId = 5 SET @Frac = CONVERT(decimal(38,18), @days_30_grid)/ 365.0;-- 30/365

    IF @Frac IS NOT NULL
    BEGIN
        SET @InterestNormal = CONVERT(decimal(38,18), @Shuma) * @RateDec * @Frac;   -- simple
    END
    ELSE IF @MethodId = 6 -- 30/365-6 (per-year hybrid)
    BEGIN
        DECLARE @sum306 decimal(38,18) = 0.0;
        DECLARE @yy306 int = YEAR(@Date1), @yyEnd306 int = YEAR(@Date2);

        WHILE @yy306 <= @yyEnd306
        BEGIN
            DECLARE @segStart306 date =
                CASE WHEN @yy306 = YEAR(@Date1) THEN @Date1 ELSE DATEFROMPARTS(@yy306,1,1) END;
            DECLARE @segEndEx306 date =
                CASE WHEN @yy306 = YEAR(@Date2) THEN @Date2 ELSE DATEFROMPARTS(@yy306+1,1,1) END;

            IF @segEndEx306 > @segStart306
            BEGIN
                DECLARE @Y1s int = YEAR(@segStart306), @M1s int = MONTH(@segStart306), @D1s int = DAY(@segStart306);
                DECLARE @Y2s int = YEAR(@segEndEx306), @M2s int = MONTH(@segEndEx306), @D2s int = DAY(@segEndEx306);

                IF @D1s > 30 SET @D1s = 30;
                IF @D2s > 30 SET @D2s = 30;

                DECLARE @Days30s int = ((@Y2s - @Y1s)*360) + ((@M2s - @M1s)*30) + (@D2s - @D1s);
                DECLARE @Den306 int =
                    CASE WHEN (@yy306 % 400 = 0) OR (@yy306 % 4 = 0 AND @yy306 % 100 <> 0) THEN 366 ELSE 365 END;

                SET @sum306 += CONVERT(decimal(38,18), @Shuma) * @RateDec
                             * ( CONVERT(decimal(38,18), @Days30s) / CONVERT(decimal(38,18), @Den306) );
            END
            SET @yy306 += 1;
        END

        SET @InterestNormal = CONVERT(decimal(19,8), @sum306);
    END
    ELSE IF @MethodId = 7  -- COMPOUND
    BEGIN
        DECLARE @factor float = POWER(1.0 + (CONVERT(float,@RateP)/100.0), CONVERT(float,@t_actact));
        SET @InterestNormal = CONVERT(decimal(38,18), @Shuma) * CONVERT(decimal(38,18), @factor - 1.0);
    END

    /* ---------- 4) DAY-COUNT FOR DISPLAY ---------- */
    DECLARE @DaysOut int =
        CASE
            WHEN @MethodId IN (1,7) THEN @DaysActSegSum
            WHEN @MethodId IN (2,3) THEN @DaysAll
            WHEN @MethodId = 4       THEN @days_30_360
            WHEN @MethodId = 5       THEN @days_30_grid
            WHEN @MethodId = 6       THEN 0
        END;

    IF @MethodId = 6
    BEGIN
        DECLARE @yyR int = YEAR(@Date1), @yyREnd int = YEAR(@Date2), @acc int = 0;
        WHILE @yyR <= @yyREnd
        BEGIN
            DECLARE @s date = CASE WHEN @yyR = YEAR(@Date1) THEN @Date1 ELSE DATEFROMPARTS(@yyR,1,1) END;
            DECLARE @e date = CASE WHEN @yyR = YEAR(@Date2) THEN @Date2 ELSE DATEFROMPARTS(@yyR+1,1,1) END;
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

    /* ---------- 5) OUTPUT ROW (Err columns NULL on success) ---------- */
    IF ISNULL(@Anticip,0) = 1
    BEGIN
        DECLARE @rf decimal(38,18) =
            CASE WHEN @Shuma = 0 THEN 0 ELSE CONVERT(decimal(38,18), @InterestNormal) / CONVERT(decimal(38,18), @Shuma) END;
        DECLARE @GjParaprake decimal(19,2) =
            CASE WHEN 1 + @rf = 0 THEN NULL ELSE ROUND(@Shuma / (1 + @rf), 2) END;
        DECLARE @InteresiAnt decimal(19,2)  = @Shuma - @GjParaprake;

        INSERT INTO @Result
        (
          ErrCode,ErrText,
          [Data Prej],[Data Deri],[Ditet],[Norma],[Metoda],
          [Shuma (Vlera fillestare)],[Interesi],[Gjendja e re],
          [Shuma (Vlera finale)],[Gj.Paraprake (anticip)],[Interesi (anticip)]
        )
        VALUES
        (
          NULL,NULL,
          CONVERT(char(10),@Date1,102), CONVERT(char(10),@Date2,102), @DaysOut, @RateP, @MethodName,
          NULL,NULL,NULL,
          @Shuma, @GjParaprake, @InteresiAnt
        );
    END
    ELSE
    BEGIN
        DECLARE @InteresiNormal2 decimal(19,2) = ROUND(@InterestNormal, 2);

        INSERT INTO @Result
        (
          ErrCode,ErrText,
          [Data Prej],[Data Deri],[Ditet],[Norma],[Metoda],
          [Shuma (Vlera fillestare)],[Interesi],[Gjendja e re],
          [Shuma (Vlera finale)],[Gj.Paraprake (anticip)],[Interesi (anticip)]
        )
        VALUES
        (
          NULL,NULL,
          CONVERT(char(10),@Date1,102), CONVERT(char(10),@Date2,102), @DaysOut, @RateP, @MethodName,
          @Shuma, @InteresiNormal2, @Shuma + @InteresiNormal2,
          NULL,NULL,NULL
        );
    END

    RETURN;
END
GO
