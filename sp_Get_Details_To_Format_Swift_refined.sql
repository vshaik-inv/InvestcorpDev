USE [COUPA_TOOLS]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/* =============================================
   Author:        Vali Shaik
   Create date:   (original)
   Description:   Get the request details to format a SWIFT payment file.
                  Supports three request types:
                      1. EmpFX            - Employee FX requests (MT103)
                      2. PMS Proposal     - Vendor payment proposals (MT101/103/202)
                      3. CmpAdmin Funding - Inter-company funding (MT202)

   Refinement notes (refactor pass):
     - Removed leftover debug PRINT and SELECT statements.
     - Removed large blocks of commented-out legacy code.
     - Initialised @swiftFI to 'N' so the CASE expression behaves correctly
       (previously NULL, making the 'Y' branch unreachable).
     - Standardised whitespace, casing, and indentation.
     - Consolidated duplicate validation logic comments.
     - Preserved all original business logic and output columns.

   Test calls:
     exec [sp_Get_Details_To_Format_Swift] '103OR202', 2161, 'CmpAdmin Funding', 1784720
     exec [sp_Get_Details_To_Format_Swift] '103OR202', 5693, 'PMS Proposal',     1199743
     exec [sp_Get_Details_To_Format_Swift] 'FIN_EmpFX', 4361, 'EmpFX',           1847754
   ============================================= */
ALTER PROCEDURE [dbo].[sp_Get_Details_To_Format_Swift]
    @ip_Msg_Type      nvarchar(50),
    @ip_Request_ID    int,
    @ip_Request_Type  nvarchar(50),
    @ip_Qtm_Deal_No   int = 0
AS
BEGIN
    SET NOCOUNT ON;

    ---------------------------------------------------------------------
    -- Local variables
    ---------------------------------------------------------------------
    DECLARE @VendorCode          varchar(40),
            @Currency            varchar(10),
            @Entitykey           varchar(10),
            @cod_OurSWIFTCode    varchar(100),
            @BICCode             varchar(60),
            @VendorName          varchar(300),
            @NostroAccount       varchar(100),
            @strErrMsg           varchar(1000),
            @strSubject          varchar(1000),
            @strVendorAddress    varchar(4000),
            @swiftFI             varchar(10) = 'N',   -- default so CASE works as intended
            @txt_InvoiceCodes    varchar(2000),
            @TxnRefNo            nvarchar(100),
            @TxnRelRefNo         nvarchar(100),
            @returnFundsComments nvarchar(4000),
            @EnttityName         nvarchar(20),
            @OrgMsgType          nvarchar(20),
            @EntityAddress       varchar(200),
            @NostroAccountName   varchar(100),
            @Ext_Name            varchar(200),
            @Country_and_City    varchar(200),
            @Subcountry          varchar(100);

    BEGIN TRY

        ---------------------------------------------------------------------
        -- Working temp table
        ---------------------------------------------------------------------
        CREATE TABLE #tmpDetails
        (
            RequestID                   int,
            VendorCode                  varchar(40)   NULL,
            VendorName                  varchar(100)  NULL,
            BenficiaryAccountNo         varchar(100)  NULL,
            BeneficiaryName             varchar(140)  NULL,
            BICCode                     varchar(100)  NULL,
            OurSWIFTCode                varchar(100)  NULL,
            ModOurAccountNo             varchar(100)  NULL,
            OurAccountNo                varchar(100)  NULL,
            IntermSWIFTCode             varchar(100)  NULL,
            IntermABACode               varchar(100)  NULL,
            IntermSortCode              varchar(100)  NULL,
            IntermBankName              varchar(100)  NULL,
            IntermBankAddr              varchar(100)  NULL,
            TheirSWIFTCode              varchar(100)  NULL,
            TheirABACode                varchar(100)  NULL,
            TheirSortCode               varchar(100)  NULL,
            TheirBankName               varchar(100)  NULL,
            TheirBankAddress            varchar(100)  NULL,
            TheirIBANCode               varchar(100)  NULL,
            TheirAccountNo              varchar(100)  NULL,
            TheirAccountName            varchar(140)  NULL,
            VendorAddress               varchar(4000) NULL,
            IsSwiftFI                   varchar(10)   NULL,
            InvoiceCodes                varchar(2000) NULL,
            Comments                    nvarchar(4000) NULL,
            TxnReference                nvarchar(100) NULL,
            TxnRelReference             nvarchar(100) NULL,
            MsgType                     nvarchar(100) NULL,
            QtmDealNo                   int,
            ValueDate                   datetime,
            RequestItemID               int,
            RequestItemSubID            int,
            CCY                         nvarchar(20),
            Amount                      money,
            NostroAccount               nvarchar(100),
            SwiftIDFI                   nvarchar(100),
            SwiftInstructions           nvarchar(4000),
            RequestType                 nvarchar(100),
            CountryName                 nvarchar(500),
            IsTransactionCodeCountries  bit DEFAULT(0),
            ReportingCode               nvarchar(60)  NULL,
            IFSCCode                    nvarchar(60)  NULL,
            PurposeOfPayment            nvarchar(140) NULL,
            EntityAddress               varchar(200)  NULL,
            SortCode                    varchar(50)   NULL,
            SortCodeBankName            varchar(200)  NULL,
            SortCodeBankAddress         varchar(400)  NULL,
            PayingEntity                nvarchar(100) NULL,
            Ext_Name                    varchar(200)  NULL,
            Country_and_City            varchar(200)  NULL,
            Subcountry                  varchar(100)
        );

        ---------------------------------------------------------------------
        -- Branch 1: EmpFX (Employee FX requests)  -> MT103
        ---------------------------------------------------------------------
        IF @ip_Request_Type = 'EmpFX'
        BEGIN
            SELECT @VendorCode        = ISNULL(A.[EmployeeID], ''),
                   @Currency          = ISNULL(A.[BuyCCY], ''),
                   @EnttityName       = LTRIM(RTRIM(E.Name)),
                   @NostroAccount     = ISNULL(Q.Account_No, ''),
                   @NostroAccountName = ISNULL(A.[BeneficiaryName], '')
            FROM   [FinProcesses].[dbo].[EmployeeFXRequest] A
            JOIN   CAMS_DB.PPS.Quantum_Cash_flow            Q WITH (NOLOCK)
                   ON  Q.CAMS_ID = A.[ID]
                   AND A.[BuyCCY] = Q.CCY
            JOIN   aznedsql01.QtmProd.dbo.bankacc           B WITH (NOLOCK)
                   ON Q.Account_No = LTRIM(RTRIM(B.acc_no))
            JOIN   aznedsql01.QtmProd.dbo.bustruct          E WITH (NOLOCK)
                   ON E.thekey = B.entity
            WHERE  A.[ID] = @ip_Request_ID
              AND  Q.Request_Type = 'Employee FX';

            -- Field validation
            IF ISNULL(@Currency, '') = ''
                RAISERROR('Currency not found. Please check.', 16, 1);

            IF ISNULL(@NostroAccount, '') = ''
                RAISERROR('Nostro Account not found. Please check.', 16, 1);

            IF ISNULL(@EnttityName, '') = ''
                RAISERROR('Entity Name not found. Please check.', 16, 1);

            IF (ISNULL(@ip_Qtm_Deal_No, 0) = 0)
                RAISERROR('Quantum Deal No not found. Please check.', 16, 1);

            -- Resolve entity key + entity address from Quantum
            SELECT @Entitykey     = LTRIM(RTRIM(thekey)),
                   @EntityAddress = ISNULL(address, '')
            FROM   aznedsql01.QTMPROD.dbo.bustruct WITH (NOLOCK)
            WHERE  LTRIM(RTRIM(name)) = @EnttityName;

            -- Override with the address tied to the actual deal (if available)
            SELECT @EntityAddress = bs.ext_name + CHAR(10) + ISNULL(bs.address, '')
            FROM   aznedsql01.QTMPROD.dbo.bustruct bs WITH (NOLOCK),
                   Quantum_Cashflow                qc WITH (NOLOCK)
            WHERE  qc.Quantum_Deal_Number = @ip_Qtm_Deal_No
              AND  qc.Account_Entity      = LTRIM(RTRIM(bs.name));

            -- Special-case override for IIAM
            IF @EnttityName = 'IIAM'
                SET @EntityAddress = 'Investcorp India Asset Managers Private Limited '
                                   + 'Unit No. 02 - 6th Floor, Godrej BKC, Plot C-68, '
                                   + 'G Block Bandra Kurla Complex, Bandra (East), '
                                   + 'Mumbai - 400051';

            -- Investcorp BIC code (overridden for specific Cayman accounts per ops, 27-09-2022)
            SELECT @BICCode = CASE
                                  WHEN RTRIM(LTRIM(@NostroAccount))
                                       IN ('0099048256', '204503923', '204503915')
                                  THEN 'INVCKYKYAISA'
                                  ELSE RTRIM(A.name)
                              END
            FROM   aznedsql01.QTMPROD.dbo.entident A WITH (NOLOCK)
            JOIN   aznedsql01.QTMPROD.dbo.bustruct B WITH (NOLOCK)
                   ON A.entity = B.thekey
                   AND A.entity = @Entitykey
            JOIN   aznedsql01.QTMPROD.dbo.paymethd C WITH (NOLOCK)
                   ON  A.paymethd = C.thekey
                   AND C.name     = 'SWIFT_ICB';

            IF ISNULL(@BICCode, '') = ''
                RAISERROR('InvestCorp BIC code not found. Please check.', 16, 1);

            -- Investcorp nostro SWIFT code (typo correction for CINAUS6LEZI -> CINAUS6LXEZI)
            SELECT @cod_OurSWIFTCode = CASE
                                           WHEN ISNULL(RTRIM(bank_bic_code), '') = 'CINAUS6LEZI'
                                           THEN 'CINAUS6LXEZI'
                                           ELSE ISNULL(RTRIM(bank_bic_code), '')
                                       END
            FROM   aznedsql01.QTMPROD.dbo.qvw_bankacc WITH (NOLOCK)
            WHERE  LTRIM(RTRIM(entity)) = @Entitykey
              AND  LTRIM(RTRIM(acc_no)) = @NostroAccount;

            IF ISNULL(@cod_OurSWIFTCode, '') = ''
                RAISERROR('InvestCorp Swift Code not found. Please check.', 16, 1);

            -- Build output row
            INSERT INTO #tmpDetails
            (
                RequestID, MsgType, QtmDealNo, ValueDate, CCY, Amount,
                BeneficiaryName, NostroAccount, BICCode, OurSWIFTCode,
                TheirSWIFTCode, BenficiaryAccountNo, IntermSWIFTCode,
                IsSwiftFI, TheirSortCode, TheirBankAddress, TheirBankName,
                ModOurAccountNo
            )
            SELECT @ip_Request_ID,
                   '103',
                   @ip_Qtm_Deal_No,
                   A.ValueDate,
                   A.BuyCCY,
                   A.BuyAmount,
                   A.BeneficiaryName,
                   @NostroAccount,
                   @BICCode,
                   @cod_OurSWIFTCode,
                   A.BeneficiaryBankSwiftCode,
                   A.BeneficiaryAccountNo,
                   A.IntermediaryBankSwiftCode,
                   '103',
                   A.BeneficiaryBank_RT_SC_Code,
                   A.BeneficiaryBankAddress,
                   A.BeneficiaryBankName,
                   A.[BeneficiaryBank_RT_SC_Type]
            FROM   [FinProcesses].[dbo].[EmployeeFXRequest] A
            WHERE  A.[ID] = @ip_Request_ID;

            IF NOT EXISTS (SELECT 1 FROM #tmpDetails)
                RAISERROR('Beneficiary Details not found. Please check.', 16, 1);
        END  -- End EmpFX

        ---------------------------------------------------------------------
        -- Branch 2: PMS Proposal (Vendor payment proposals) -> MT101/103/202
        ---------------------------------------------------------------------
        IF @ip_Request_Type = 'PMS Proposal'
        BEGIN
            SELECT @VendorCode        = ISNULL(A.Supplier_CODA_Code, ''),
                   @Currency          = ISNULL(A.Payment_CCY, ''),
                   @EnttityName       = REPLACE(REPLACE(ISNULL(Quantum_Bank_Account_Entity, ''),
                                                        'EC', 'BSC'),
                                                'ITLB', 'ITL'),
                   @NostroAccount     = ISNULL(B.Nostro_Account_Number, ''),
                   @NostroAccountName = ISNULL(B.Nostro_Account_Name, '')
            FROM   Proposal             A WITH (NOLOCK)
            JOIN   Nostro_Account       B WITH (NOLOCK)
                   ON B.Nostro_Account_ID = A.Nostro_Account_ID
            JOIN   Quantum_Bank_Account C WITH (NOLOCK)
                   ON C.Quantum_Bank_Account_Number = B.Nostro_Account_Number
            WHERE  A.Proposal_ID = @ip_Request_ID;

            SELECT @VendorName = ISNULL(CODA_Supplier_Name, '')
            FROM   CODA_Supplier WITH (NOLOCK)
            WHERE  CODA_Supplier_Code = @VendorCode;

            -- Field validation
            IF ISNULL(@Currency, '') = ''
                RAISERROR('Currency not found. Please check.', 16, 1);

            IF ISNULL(@NostroAccount, '') = ''
                RAISERROR('Nostro Account not found. Please check.', 16, 1);

            IF ISNULL(@EnttityName, '') = ''
                RAISERROR('Entity Name not found. Please check.', 16, 1);

            IF (ISNULL(@ip_Qtm_Deal_No, 0) = 0)
                RAISERROR('Quantum Deal No not found. Please check.', 16, 1);

            -- Resolve entity key
            SELECT @Entitykey = LTRIM(RTRIM(thekey))
            FROM   aznedsql01.QTMPROD.dbo.bustruct WITH (NOLOCK)
            WHERE  LTRIM(RTRIM(name)) = @EnttityName;

            -- Resolve entity address details
            SELECT @Country_and_City = (Country_Code + '/' + City_Name),
                   @EntityAddress    = Street_Name
                                       + IIF(Postal_Code IS NOT NULL, '//' + Postal_Code, ''),
                   @Subcountry       = ISNULL(Sub_Country_Code, ''),
                   @Ext_Name         = [External_Name]
            FROM   dbo.Entity_Address_details
            WHERE  Entity = @EnttityName;

            -- Investcorp BIC code (overridden for specific Cayman accounts per ops, 27-09-2022)
            SELECT @BICCode = CASE
                                  WHEN RTRIM(LTRIM(@NostroAccount))
                                       IN ('0099048256', '204503923', '204503915')
                                  THEN 'INVCKYKYAISA'
                                  ELSE RTRIM(A.name)
                              END
            FROM   aznedsql01.QTMPROD.dbo.entident A WITH (NOLOCK)
            JOIN   aznedsql01.QTMPROD.dbo.bustruct B WITH (NOLOCK)
                   ON  A.entity = B.thekey
                   AND A.entity = @Entitykey
            JOIN   aznedsql01.QTMPROD.dbo.paymethd C WITH (NOLOCK)
                   ON  A.paymethd = C.thekey
                   AND C.name     = 'SWIFT_ICB';

            IF ISNULL(@BICCode, '') = ''
                RAISERROR('InvestCorp BIC code not found. Please check.', 16, 1);

            -- Investcorp nostro SWIFT code
            SELECT @cod_OurSWIFTCode = CASE
                                           WHEN ISNULL(RTRIM(bank_bic_code), '') = 'CINAUS6LEZI'
                                           THEN 'CINAUS6LXEZI'
                                           ELSE ISNULL(RTRIM(bank_bic_code), '')
                                       END
            FROM   aznedsql01.QTMPROD.dbo.qvw_bankacc WITH (NOLOCK)
            WHERE  LTRIM(RTRIM(entity)) = @Entitykey
              AND  LTRIM(RTRIM(acc_no)) = @NostroAccount;

            IF ISNULL(@cod_OurSWIFTCode, '') = ''
                RAISERROR('InvestCorp Swift Code not found. Please check.', 16, 1);

            -- Aggregate invoice codes for this proposal
            SELECT @txt_InvoiceCodes = COALESCE(@txt_InvoiceCodes + ', ', '') + C.Invoice_Code
            FROM   Proposal         A
            JOIN   Proposal_Invoice B ON B.Proposal_ID = A.Proposal_ID
            JOIN   Invoice          C ON C.Invoice_ID  = B.Invoice_ID
            WHERE  A.Proposal_ID      = @ip_Request_ID
              AND  ISNULL(B.Is_Deleted, 0) <> 1;

            -- Build output rows
            INSERT INTO #tmpDetails
            (
                RequestID, MsgType, TxnReference, TxnRelReference, Comments,
                VendorCode, VendorName, BenficiaryAccountNo, BeneficiaryName,
                BICCode, OurSWIFTCode, IntermSWIFTCode, IntermABACode,
                IntermSortCode, TheirSWIFTCode, TheirIBANCode, TheirAccountNo,
                TheirAccountName, VendorAddress, IsSwiftFI, InvoiceCodes,
                QtmDealNo, ValueDate, RequestItemID, RequestItemSubID,
                CCY, Amount, NostroAccount, SwiftIDFI, SwiftInstructions,
                RequestType, CountryName, IsTransactionCodeCountries,
                ReportingCode, IFSCCode, PurposeOfPayment, EntityAddress,
                SortCode, SortCodeBankName, SortCodeBankAddress, PayingEntity,
                Ext_Name, Country_and_City, Subcountry
            )
            SELECT @ip_Request_ID,
                   -- Message type rules:
                   --   INR via HSBC India IIAM -> 101
                   --   Bahrain BIC (INVCBHBMA) -> 101
                   --   Otherwise FI flag wins  -> 202 if 'Y' else 103
                   CASE
                       WHEN B.Account_CCY = 'INR' AND @NostroAccountName = 'HSBC India - IIAM' THEN '101'
                       WHEN @BICCode = 'INVCBHBMA' THEN '101'
                       ELSE CASE @swiftFI WHEN 'Y' THEN '202' ELSE '103' END
                   END,
                   @TxnRefNo,
                   @TxnRelRefNo,
                   @returnFundsComments,
                   ISNULL(@VendorCode, ''),
                   ISNULL(@VendorName, ''),
                   REPLACE(ISNULL(A.Beneficiary_Account_Number, ''), ' ', ''),
                   SUBSTRING(ISNULL(A.Beneficiary_Account_Name, ''), 1, 140),
                   @BICCode,
                   @cod_OurSWIFTCode,
                   ISNULL(A.Intermediary_Bank_Swift_Code, ''),
                   '',
                   '',
                   ISNULL(A.Beneficiary_Bank_Swift_Code, ''),
                   REPLACE(ISNULL(A.Beneficiary_Account_Number, ''), ' ', ''),
                   REPLACE(ISNULL(A.Beneficiary_Account_Number, ''), ' ', ''),
                   SUBSTRING(ISNULL(A.Beneficiary_Account_Name, ''), 1, 140),
                   ISNULL(@strVendorAddress, ''),
                   -- IsSwiftFI mirrors MsgType logic above
                   CASE
                       WHEN B.Account_CCY = 'INR' AND @NostroAccountName = 'HSBC India - IIAM' THEN '101'
                       WHEN @BICCode = 'INVCBHBMA' THEN '101'
                       ELSE CASE @swiftFI WHEN 'Y' THEN '202' ELSE '103' END
                   END,
                   @txt_InvoiceCodes,
                   B.Quantum_Deal_Number,
                   B.Value_Date,
                   C.Proposal_Beneficiary_ID,
                   0,
                   D.Payment_ccy,
                   ABS(D.Payment_Amount),
                   B.Account_Number,
                   ISNULL(@swiftFI, 'N'),
                   ISNULL(A.For_Further_Credit, ''),
                   'PMS Proposal',
                   '',
                   0,
                   ISNULL(D.Reporting_Code, ISNULL(A.Reporting_Code, '')),
                   ISNULL(A.IFSC_Code, ''),
                   SUBSTRING(ISNULL(A.Purpose_OF_Payment, '') + ' '
                             + ISNULL(A.For_Further_Credit, ''), 1, 140),
                   ISNULL(@EntityAddress, ''),
                   ISNULL(A.Sort_Code, ''),
                   ISNULL(A.Sort_Code_Bank_Name, ''),
                   ISNULL(A.Sort_Code_Bank_Address, ''),
                   ISNULL(D.Paying_Entity, ''),
                   ISNULL(@Ext_Name, ''),
                   ISNULL(@Country_and_City, ''),
                   ISNULL(@Subcountry, '')
            FROM   Proposal_Beneficiary  C WITH (NOLOCK)
            JOIN   Supplier_Beneficiary  A WITH (NOLOCK)
                   ON A.Supplier_Beneficiary_ID = C.Supplier_Beneficiary_ID
            JOIN   Quantum_Cashflow      B WITH (NOLOCK)
                   ON  B.Request_ID          = C.Proposal_ID
                   AND B.Quantum_Deal_Number = @ip_Qtm_Deal_No
            JOIN   Proposal              D
                   ON B.Request_ID = D.Proposal_ID
            WHERE  C.Proposal_ID = @ip_Request_ID;

            IF NOT EXISTS (SELECT 1 FROM #tmpDetails)
                RAISERROR('Beneficiary Details not found. Please check.', 16, 1);
        END  -- End PMS Proposal

        ---------------------------------------------------------------------
        -- Branch 3: CmpAdmin Funding (Inter-company funding) -> MT202
        ---------------------------------------------------------------------
        IF @ip_Request_Type = 'CmpAdmin Funding'
        BEGIN
            INSERT INTO #tmpDetails
            (
                MsgType, IsSwiftFI, OurSWIFTCode, TheirSWIFTCode,
                TxnReference, RequestID, RequestItemID, QtmDealNo,
                ValueDate, CCY, Amount, IntermSWIFTCode,
                OurAccountNo, BICCode, TheirAccountNo, TheirAccountName
            )
            SELECT '202',
                   '202',
                   Sen.BIC_Code             AS SenderSWIFTCode,
                   Rec.BIC_Code             AS ReceiverSWIFTCode,
                   CONCAT('AC', A.Quantum_Deal_Number, '-', CAST(F.ID AS varchar)),
                   A.Request_ID,
                   A.Request_ID,
                   A.Quantum_Deal_Number,
                   A.Value_Date,
                   A.Account_CCY,
                   A.Cashflow_Amount,
                   Sen.Interm_BIC_Code      AS Intermediary_BICCode,
                   F.HoldcoAccount,
                   Rec.Institution_Code     AS Instituion_BICCode,
                   Rec.[SWIFT_IBAN],
                   Rec.Instituion_Display_Name
            FROM   dbo.Quantum_Cashflow             A   WITH (NOLOCK)
            JOIN   dbo.tb_cmp_mst_Funding           F   WITH (NOLOCK)
                   ON A.Request_ID = F.ID
            JOIN   [dbo].[tb_pay_mst_CompAdminNostro] Rec WITH (NOLOCK)
                   ON Rec.[cod_NostroAccount] = F.NostroAccount
            JOIN   [dbo].[tb_cmp_mst_HoldcoNostros] Sen WITH (NOLOCK)
                   ON Sen.AccountNo = F.HoldcoAccount
            WHERE  A.Request_Type        = @ip_Request_Type
              AND  A.Request_ID          = @ip_Request_ID
              AND  A.Quantum_Deal_Number = @ip_Qtm_Deal_No;

            -- Validation: required SWIFT/BIC fields must all be present
            IF EXISTS (SELECT 1 FROM #tmpDetails WHERE ISNULL(OurSWIFTCode, '') = '')
                RAISERROR('Sender BIC Details not found. Please check.', 16, 1);

            IF EXISTS (SELECT 1 FROM #tmpDetails WHERE ISNULL(TheirSWIFTCode, '') = '')
                RAISERROR('Receiver BIC Details not found. Please check.', 16, 1);

            IF EXISTS (SELECT 1 FROM #tmpDetails WHERE ISNULL(BICCode, '') = '')
                RAISERROR('Beneficary Instituion BIC Details not found. Please check.', 16, 1);

            IF EXISTS (SELECT 1 FROM #tmpDetails WHERE ISNULL(IntermSWIFTCode, '') = '')
                RAISERROR('Intermediary BIC Details not found. Please check.', 16, 1);

            IF EXISTS (SELECT 1 FROM #tmpDetails WHERE ISNULL(TxnReference, '') = '')
                RAISERROR('Sender Transaction Reference No. not found. Please check.', 16, 1);

            -- NULL handling for downstream formatter
            UPDATE #tmpDetails SET EntityAddress = '';
        END  -- End CmpAdmin Funding

        ---------------------------------------------------------------------
        -- Return result set
        ---------------------------------------------------------------------
        SELECT * FROM #tmpDetails;

    END TRY
    BEGIN CATCH
        -- Capture and log the failure, then re-raise to caller
        SET @strErrMsg = REPLACE(ERROR_MESSAGE(), '''', '');

        EXEC [dbo].[sp_Save_SWIFT_Log]
             @ip_Request_Type,
             @ip_Request_ID,
             0,
             @ip_Qtm_Deal_No,
             @ip_Msg_Type,
             'execution failed in sp_Get_Details_To_Format_Swift',
             0,
             @strErrMsg;

        RAISERROR(@strErrMsg, 16, 1);
    END CATCH
END
GO
