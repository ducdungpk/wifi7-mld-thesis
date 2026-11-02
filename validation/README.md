# Bằng chứng kiểm tra môi trường

Các gói được giữ nguyên từ quá trình kiểm tra môi trường ns-3.46.1 có hiệu chỉnh cục bộ trước các thực nghiệm cuối.

| Gói 								| Nội dung 													|	
|-----------------------------------|-----------------------------------------------------------|
| foundation-final-results.tar.gz 	| Kết quả 95 case, mã kiểm tra và thông tin môi trường 		|
| foundation-phase4-results.tar.gz 	| Kết quả 15 case kiểm tra cơ chế còn lại 					|
| focus-ba-results.tar.gz 			| Dữ liệu theo thời gian để đối chiếu cảnh báo Block Ack 	|

Tổng cộng 110 case theo kế hoạch đã được thực hiện qua hai phần. Không ghi nhận luồng hoạt động nhận 0 gói trong bộ này. Một cảnh báo theo dõi trạng thái Block Ack được giữ lại và đối chiếu bằng nhật ký chuyển trạng thái cùng xác nhận khung; không mô tả toàn bộ bộ kiểm tra là tất cả kiểm tra đều PASS.

ns3_prepare.sh sử dụng foundation-final-results.tar.gz để khôi phục ba phần mã C++ và đối chiếu hai tệp thư viện đã hiệu chỉnh bằng SHA-256. Bộ đầu mối chuẩn hóa sử dụng cùng kế hoạch 110 case; kết quả chạy lại được lưu riêng và không thay thế các gói bằng chứng trong thư mục này.