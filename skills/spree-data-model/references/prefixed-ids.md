# Spree 6 prefixed ID table

Generated from `grep -rn "has_prefix_id :" spree/core/app/models` (Spree 6.0). Every ID has the shape `<prefix>_<sqids>` — e.g. `prod_86Rf07xd4z`. STI subclasses inherit their parent's prefix (every `Spree::Gateway` subclass is `pm_`, every calculator `calc_`, every promotion rule `prorule_`).

To confirm a prefix in an installed app: `Spree::Product._prefix_id_prefix` (or `record.prefixed_id`).

```ruby
Spree::Order.find_by_prefix_id!('or_m3Rp9wXz')   # raises ActiveRecord::RecordNotFound
Spree::Order.find_by_prefix_id('or_m3Rp9wXz')    # nil when missing
Spree::Order.decode_prefixed_id('or_m3Rp9wXz')   # integer PK (nil for another model's prefix)
Spree::PrefixedId.decode_prefixed_id('prod_…')  # integer PK for ANY prefix — no model check
```

`find_by_prefix_id(!)` and the class-level `decode_prefixed_id` both check the prefix — a `prod_` ID passed to `Spree::Order.find_by_prefix_id` finds nothing, and `Spree::Order.decode_prefixed_id` returns `nil`. Only the module-level `Spree::PrefixedId.decode_prefixed_id` decodes any prefix; don't use it on untrusted input where the model matters.

Every prefix has exactly one owning model.

## Look-alike prefixes (watch out)

- `ps_` is `Spree::PaymentSession`; `Spree::PaymentSource` is `psrc_` (it was `ps_` in 5.x, shared with sessions — a stored payment `source_id` starting `ps_` for a non-card source needs `ps_` → `psrc_`; the encoded part is unchanged).
- `crule_` is `Spree::CollectionRule`; `Spree::CommissionRule` is `comrule_` (`crule_` in 6.0 pre-release builds).
- `discount_` is `Spree::OrderPromotion` (an applied promotion); the money row `Spree::Discount` is `disc_`.
- `sub_` is `Spree::NewsletterSubscriber`; `sq_` is `Spree::SavedReport`; `re_` is `Spree::Refund`.
- `txnmy_` (`Spree::Taxonomy`) and `txrule_` (`Spree::TaxonRule`) belong to deprecated upgrade-only models.

Non-model tokens that look like prefixed IDs: API keys are `pk_…` (publishable) and `sk_…` (secret).

## Full table

| Prefix | Model |
|---|---|
| `addr_` | Spree::Address |
| `adm_` | AdminUser (Spree.admin_user_class, via AdminUserMethods) |
| `ao_` | Spree::AllowedOrigin |
| `key_` | Spree::ApiKey |
| `calc_` | Spree::Calculator |
| `cart_` | Spree::Cart |
| `cat_` | Spree::Catalog |
| `cata_` | Spree::CatalogAssignment |
| `com_` | Spree::CatalogOrderMinimum |
| `catp_` | Spree::CatalogProduct |
| `cqr_` | Spree::CatalogQuantityRule |
| `ctg_` | Spree::Category |
| `ch_` | Spree::Channel |
| `claim_` | Spree::Claim |
| `cli_` | Spree::ClaimLineItem |
| `clr_` | Spree::ClaimReason |
| `coll_` | Spree::Collection |
| `crule_` | Spree::CollectionRule |
| `cline_` | Spree::CommissionLine |
| `crate_` | Spree::CommissionRate |
| `crval_` | Spree::CommissionRateValue |
| `comrule_` | Spree::CommissionRule |
| `comp_` | Spree::Company |
| `cinv_` | Spree::CompanyInvitation |
| `cmem_` | Spree::CompanyMembership |
| `consent_` | Spree::ConsentRecord |
| `coupon_` | Spree::CouponCode |
| `card_` | Spree::CreditCard |
| `cf_` | Spree::CustomField |
| `cfdef_` | Spree::CustomFieldDefinition |
| `cg_` | Spree::CustomerGroup |
| `cust_` | Customer (Spree.customer_class, via CustomerMethods) |
| `df_` | Spree::DataFeed |
| `dsr_` | Spree::DataRequest |
| `dlv_` | Spree::Delivery |
| `dm_` | Spree::DeliveryMethod |
| `dmrule_` | Spree::DeliveryMethodRule |
| `dms_` | Spree::DeliveryMethodService |
| `og_` | Spree::DeliveryOriginGroup |
| `fp_` | Spree::DeliveryProfile |
| `dr_` | Spree::DeliveryRate |
| `dz_` | Spree::DeliveryZone |
| `dzm_` | Spree::DeliveryZoneMember |
| `dig_` | Spree::DigitalAsset |
| `dl_` | Spree::DigitalLink |
| `disc_` | Spree::Discount |
| `exch_` | Spree::Exchange |
| `eli_` | Spree::ExchangeLineItem |
| `exp_` | Spree::Export |
| `extref_` | Spree::ExternalReference |
| `fee_` | Spree::Fee |
| `ful_` | Spree::Fulfillment |
| `fi_` | Spree::FulfillmentItem |
| `gcus_` | Spree::GatewayCustomer |
| `gc_` | Spree::GiftCard |
| `gcb_` | Spree::GiftCardBatch |
| `imp_` | Spree::Import |
| `immap_` | Spree::ImportMapping |
| `imrow_` | Spree::ImportRow |
| `int_` | Spree::Integration |
| `inv_` | Spree::Invitation |
| `li_` | Spree::LineItem |
| `mkt_` | Spree::Market |
| `media_` | Spree::Media |
| `sub_` | Spree::NewsletterSubscriber |
| `opt_` | Spree::OptionType |
| `optval_` | Spree::OptionValue |
| `or_` | Spree::Order |
| `ocr_` | Spree::OrderCancellationReason |
| `ogrp_` | Spree::OrderGroup |
| `discount_` | Spree::OrderPromotion |
| `orule_` | Spree::OrderRoutingRule |
| `pkgtype_` | Spree::PackageType |
| `py_` | Spree::Payment |
| `pce_` | Spree::PaymentCaptureEvent |
| `pm_` | Spree::PaymentMethod |
| `ps_` | Spree::PaymentSession |
| `pss_` | Spree::PaymentSetupSession |
| `psrc_` | Spree::PaymentSource |
| `paysp_` | Spree::PaymentSplit |
| `pol_` | Spree::Policy |
| `price_` | Spree::Price |
| `pat_` | Spree::PriceAdjustmentTier |
| `pl_` | Spree::PriceList |
| `prule_` | Spree::PriceRule |
| `prod_` | Spree::Product |
| `pp_` | Spree::ProductPublication |
| `prodsub_` | Spree::ProductSubmission |
| `pt_` | Spree::ProductType |
| `promo_` | Spree::Promotion |
| `pact_` | Spree::PromotionAction |
| `procat_` | Spree::PromotionCategory |
| `prorule_` | Spree::PromotionRule |
| `po_` | Spree::PurchaseOrder |
| `poi_` | Spree::PurchaseOrderItem |
| `rt_` | Spree::RefreshToken |
| `re_` | Spree::Refund |
| `rr_` | Spree::RefundReason |
| `ret_` | Spree::Return |
| `rli_` | Spree::ReturnLineItem |
| `rar_` | Spree::ReturnReason |
| `role_` | Spree::Role |
| `sq_` | Spree::SavedReport |
| `sel_` | Spree::Seller |
| `vpo_` | Spree::SellerPayout |
| `selreq_` | Spree::SellerRequirement |
| `selsub_` | Spree::SellerRequirementSubmission |
| `vtr_` | Spree::SellerTransfer |
| `lbl_` | Spree::ShippingLabel |
| `sl_` | Spree::StockLevel |
| `sloc_` | Spree::StockLocation |
| `sm_` | Spree::StockMovement |
| `sr_` | Spree::StockReceipt |
| `sri_` | Spree::StockReceiptItem |
| `res_` | Spree::StockReservation |
| `st_` | Spree::StockTransfer |
| `sti_` | Spree::StockTransferItem |
| `store_` | Spree::Store |
| `credit_` | Spree::StoreCredit |
| `sccat_` | Spree::StoreCreditCategory |
| `scevt_` | Spree::StoreCreditEvent |
| `sctype_` | Spree::StoreCreditType |
| `sup_` | Spree::Supplier |
| `taxcat_` | Spree::TaxCategory |
| `cert_` | Spree::TaxExemptionCertificate |
| `txi_` | Spree::TaxIdentifier |
| `tl_` | Spree::TaxLine |
| `tax_` | Spree::TaxRate |
| `txrule_` | Spree::TaxonRule |
| `txnmy_` | Spree::Taxonomy |
| `uid_` | Spree::UserIdentity |
| `variant_` | Spree::Variant |
| `whd_` | Spree::WebhookDelivery |
| `whe_` | Spree::WebhookEndpoint |
| `wl_` | Spree::Wishlist |
| `wi_` | Spree::WishlistItem |
| `zone_` | Spree::Zone |
