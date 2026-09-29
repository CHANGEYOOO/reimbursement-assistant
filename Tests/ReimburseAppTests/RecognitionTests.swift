import Testing
@testable import ReimburseApp

@Suite struct RecognitionTests {
    @Test func separatedOrderPaymentUsesAlignedRightColumn() {
        let lines = [
            Recognition.PositionedText(text: "实付价¥72价格明细", x: 0.46, y: 0.56),
            Recognition.PositionedText(text: "实付款 共减¥1.8", x: 0.19, y: 0.414),
            Recognition.PositionedText(text: "¥417", x: 0.88, y: 0.416),
        ]
        #expect(Recognition.positionedAmount(in: lines)?.amount == 417)
    }

    @Test func wholeOrderPaymentBeatsProductPayments() {
        let lines = [
            Recognition.PositionedText(text: "实付¥10.93", x: 0.87, y: 0.464),
            Recognition.PositionedText(text: "实付¥7.04", x: 0.88, y: 0.359),
            Recognition.PositionedText(text: "实付款¥18.97", x: 0.86, y: 0.177),
        ]
        #expect(Recognition.positionedAmount(in: lines)?.amount == Decimal(string: "18.97"))
    }

    @Test func commonPlatformOrderTotalsBeatLineItemsAndDiscounts() {
        let cases: [(String, String)] = [
            ("闲鱼\n商品总价359\n店铺优惠-60\n平台优惠-28\n订单实付款 ¥271", "271"),
            ("闲鱼\n商品实付价72\n店铺优惠1.8\n订单实付款417", "417"),
            ("闲鱼\n商品实付价75.22\n商品实付价75.22\n订单实付款501.52", "501.52"),
            ("美团团购\n标价160\n实付151\n成长值+151", "151"),
            ("京东\n原价249\n节省0.3\n实付款合计248.7", "248.7"),
            ("淘宝闪购\n商品实付价4.22\n商品实付价25.88\n优惠15.2\n实付款31.1", "31.1"),
            ("淘宝闪购\n推荐商品¥199\n优惠18.22\n实付18.58", "18.58"),
            ("淘宝闪购\n商品实付价10.93\n商品实付价7.04\n优惠11.93\n实付款18.97", "18.97"),
        ]
        for (text, expected) in cases {
            #expect(Recognition.suggest(from: text).amount == Decimal(string: expected))
        }
    }

    @Test func orderListCannotBeReducedToOnePayment() {
        let suggestion = Recognition.suggest(from: "全部订单\n实付款108\n实付款29.9\n实付款37.86")
        #expect(suggestion.amount == nil)
        #expect(suggestion.warning?.contains("订单列表") == true)
    }

    @Test func orderSubtotalRequiresConfirmation() {
        let suggestion = Recognition.suggest(from: "美团外卖\n商品26.88\n优惠-13\n商品费用合计21.18\n推荐商品¥61.20")
        #expect(suggestion.amount == Decimal(string: "21.18"))
        #expect(suggestion.warning?.contains("未见实付标识") == true)
    }

    @Test func paidAmountTakesPriorityOverDiscount() {
        let suggestion = Recognition.suggest(from: "优惠 ¥8\n实付 ¥22.80\n餐饮")

        #expect(suggestion.amount == Decimal(string: "22.80"))
        #expect(suggestion.category == .meals)
    }

    @Test func conflictingPaidAmountsNeedReview() {
        let suggestion = Recognition.suggest(from: "实付 ¥22.80\n已支付 ¥25.00")

        #expect(suggestion.amount == nil)
        #expect(suggestion.warning != nil)
    }

    @Test func taxiIsTransport() {
        #expect(Recognition.suggest(from: "打车行程\n已支付 18.00").category == .transport)
    }

    @Test func diningIsMeals() {
        #expect(Recognition.suggest(from: "餐饮订单\n实付 18.00").category == .meals)
    }

    @Test func unknownContentNeedsCategoryReview() {
        let suggestion = Recognition.suggest(from: "订单完成\n实付 18.00")

        #expect(suggestion.category == .uncategorized)
        #expect(suggestion.warning != nil)
    }

    @Test func separatedPaidAmountBeatsDiscount() {
        let text = """
        滴滴打车
        已支付
        本次行程已结束
        呼叫返程
        薛师傅
        44.26元
        已优惠17.21元
        """
        let suggestion = Recognition.suggest(from: text)

        #expect(suggestion.amount == Decimal(string: "44.26"))
        #expect(suggestion.category == .transport)
    }

    @Test func separatedConflictingAmountsNeedReview() {
        let suggestion = Recognition.suggest(from: "已支付\n44.26元\n45.26元\n优惠17.21元")

        #expect(suggestion.amount == nil)
        #expect(suggestion.warning != nil)
    }

    @Test func adjacentPaidAmountWithoutSpaceBeatsDiscount() {
        let suggestion = Recognition.suggest(from: "优惠￥8\n实付￥22.8")

        #expect(suggestion.amount == Decimal(string: "22.8"))
    }

    @Test func recognizedCluesRemainAvailableForReview() {
        let suggestion = Recognition.suggest(from: "薛师傅\n浙ABL0396\n已支付\n44.26元")

        #expect(suggestion.recognizedText.contains("薛师傅"))
        #expect(suggestion.recognizedText.contains("浙ABL0396"))
    }

    @Test func originalPriceIsNeverTreatedAsSeparatedPayment() {
        let suggestion = Recognition.suggest(from: "已支付\n商品原价100元\n优惠20元")

        #expect(suggestion.amount == nil)
        #expect(suggestion.warning != nil)
    }

    @Test func directPaymentIsNotConflictedByFollowingOriginalPrice() {
        let suggestion = Recognition.suggest(from: "实付￥22.8\n原价￥30")

        #expect(suggestion.amount == Decimal(string: "22.8"))
    }

    @Test func distantPaidAmountSurvivesPromotionAmounts() {
        var lines = Array(repeating: "行程信息", count: 43)
        lines[0] = "滴滴打车"
        lines[20] = "已支付"
        lines[23] = "打车减20元"
        lines[30] = "节省17.21元"
        lines[35] = "最高返10元立减券"
        lines[38] = "5元券"
        lines[41] = "44.26元〉"
        lines[42] = "已优惠17.21元"

        let suggestion = Recognition.suggest(from: lines.joined(separator: "\n"))
        #expect(suggestion.amount == Decimal(string: "44.26"))
        #expect(suggestion.warning != nil)
    }

    @Test func distantDistinctPaidCandidatesRemainAmbiguous() {
        let suggestion = Recognition.suggest(from: "已支付\n行程信息\n44.26元\n其他费用45.26元")

        #expect(suggestion.amount == nil)
        #expect(suggestion.warning != nil)
    }

    @Test func OCRCouponVariantDoesNotCompeteWithPaidAmount() {
        let suggestion = Recognition.suggest(from: "已支付\n5元劵\n10元劵\n44.26元〉\n已优惠17.21元")

        #expect(suggestion.amount == Decimal(string: "44.26"))
        #expect(suggestion.warning != nil)
    }

    @Test func DirectPaymentConflictsWithSeparatedPaidStatus() {
        let suggestion = Recognition.suggest(from: "实付￥22.8\n已支付\n25元")

        #expect(suggestion.amount == nil)
        #expect(suggestion.warning != nil)
    }

    @Test func teaAndCoffeeOrdersAreMeals() {
        for merchant in ["闪购 古茗（新塘店）", "奶茶", "咖啡", "茶饮"] {
            let suggestion = Recognition.suggest(from: "\(merchant)\n实付￥22.8")
            #expect(suggestion.category == .meals)
        }
    }

    @Test func successfulDebitWithSignedAmountUsesExpenseMagnitude() {
        let suggestion = Recognition.suggest(from: "高德打车\n-56.21\n自动扣款成功\n高德打车免密支付")

        #expect(suggestion.amount == Decimal(string: "56.21"))
        #expect(suggestion.category == .transport)
        #expect(suggestion.warning?.contains("人工核对") == true)
    }

    @Test func refundOrIncomingSignedAmountIsNotAnExpense() {
        for text in ["高德打车\n-56.21\n退款成功", "高德打车\n-56.21\n收款成功"] {
            #expect(Recognition.suggest(from: text).amount == nil)
        }
    }

    @Test func signedDiscountDoesNotReplacePaidAmount() {
        let suggestion = Recognition.suggest(from: "餐饮\n实付 ¥22.80\n优惠 -8.00\n支付成功")

        #expect(suggestion.amount == Decimal(string: "22.80"))
    }

    @Test func conflictingSignedDebitsNeedManualEntry() {
        let suggestion = Recognition.suggest(from: "高德打车\n-56.21\n-12.00\n自动扣款成功")

        #expect(suggestion.amount == nil)
    }

    @Test func negativeAmountsDoNotRequirePaymentStatus() {
        for line in ["-56.21", "−56.21元", "-¥56.21", "¥-56.21", "支出 -56.21", "付款金额：-56.21"] {
            let suggestion = Recognition.suggest(from: "打车订单\n\(line)")
            #expect(suggestion.amount == Decimal(string: "56.21"))
            #expect(suggestion.warning?.contains("人工核对") == true)
        }
    }

    @Test func negativeDiscountAndRefundStillNeedManualEntry() {
        #expect(Recognition.suggest(from: "优惠 -8.00\n餐饮订单").amount == nil)
        #expect(Recognition.suggest(from: "退款 -56.21\n订单详情").amount == nil)
    }

    @Test func longNegativeOrderNumbersAreNotAmounts() {
        let text = "账单\n裕海便利店\n-1.00\n支付成功\n-10021002608301037320738472323868\n-81842359631105001\n可在支持商户扫码退款"
        #expect(Recognition.suggest(from: text).amount == 1)
    }

    @Test func FooterCollectionWordsDoNotSuppressExpense() {
        let cases: [(String, Decimal)] = [
            ("账单\n蜜雪冰城\n-8.63\n支付成功\n发起群收款", Decimal(string: "8.63")!),
            ("账单详情\n全家FamilyMart\n-7.20\n交易成功\n收款方全称", Decimal(string: "7.20")!),
            ("账单\n扫二维码付款-给出租车\n-40.00\n支付成功\n收款方备注\n二维码收款", Decimal(string: "40.00")!),
        ]
        for (text, expected) in cases { #expect(Recognition.suggest(from: text).amount == expected) }
    }

    @Test func ExplicitIncomingTransactionIsNotExpense() {
        #expect(Recognition.suggest(from: "账单详情\n退款成功\n-56.21").amount == nil)
        #expect(Recognition.suggest(from: "账单详情\n收款成功\n-56.21").amount == nil)
    }

    @Test func recognizesTransactionDateAcrossCommonFormats() {
        #expect(Recognition.suggest(from: "支付时间\n2026年8月30日 10:37:34\n实付 1.00").date == "2026-08-30")
        #expect(Recognition.suggest(from: "支付时间\n2026-09-01 19:01:05\n实付 90.37").date == "2026-09-01")
        #expect(Recognition.suggest(from: "转账时间\n2026/9/21 08:40:58\n实付 40.00").date == "2026-09-21")
    }

    @Test func paymentDateWinsOverTripDate() {
        let text = "支付时间\n2026-09-01 19:01:05\n乘车时间\n2026-09-01 18:06:00"
        #expect(Recognition.suggest(from: text).date == "2026-09-01")
    }

    @Test func invalidOrAmbiguousDatesStayBlank() {
        #expect(Recognition.suggest(from: "支付时间\n2026-02-30\n实付 1.00").date == nil)
        #expect(Recognition.suggest(from: "2026-08-30\n2026-09-01\n实付 1.00").date == nil)
    }
}
