-- Staging Tables
CREATE TABLE `peppermayo.staging_orders` AS 
SELECT * FROM `peppermayo.orders_master` LIMIT 0;

CREATE TABLE `peppermayo.staging_order_items` AS 
SELECT * FROM `peppermayo.order_items_master` LIMIT 0;